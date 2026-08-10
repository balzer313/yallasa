import Foundation

/// What the server told us about the archive, so the next refresh can ask "is it
/// still the same one" instead of downloading ninety megabytes to find out.
public struct FeedResourceValidators: Codable, Hashable, Sendable {
    public var entityTag: String?
    public var lastModified: String?
    public var contentLength: Int64?

    public init(entityTag: String? = nil, lastModified: String? = nil, contentLength: Int64? = nil) {
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.contentLength = contentLength
    }

    public var isEmpty: Bool {
        (entityTag?.isEmpty ?? true) && (lastModified?.isEmpty ?? true) && contentLength == nil
    }

    /// Whether these validators describe the same bytes as `other`.
    ///
    /// Only `ETag` and `Last-Modified` are consulted. `Content-Length` is
    /// deliberately ignored: `gtfs.mot.gov.il` answers a HEAD with `200` and a
    /// `Content-Length` of a few kilobytes for an archive that is 141 MB on GET,
    /// so a length comparison would report "changed" on every single refresh —
    /// or, with the comparison the other way round, "unchanged" on a feed that
    /// really had changed. A length is fine for sizing a progress bar and worth
    /// nothing as a validator.
    ///
    /// Absence is never treated as a match. A server that sends neither an ETag
    /// nor a `Last-Modified` gives us no way to know, and the safe answer there
    /// is "assume it changed" — a wasted download beats a timetable that is
    /// quietly a month stale.
    public func matches(_ other: FeedResourceValidators) -> Bool {
        if let mine = entityTag, let theirs = other.entityTag, !mine.isEmpty, !theirs.isEmpty {
            return FeedResourceValidators.normalise(tag: mine) == FeedResourceValidators.normalise(tag: theirs)
        }
        if let mine = lastModified, let theirs = other.lastModified, !mine.isEmpty, !theirs.isEmpty {
            return mine == theirs
        }
        return false
    }

    /// Strips the weak-validator prefix and the surrounding quotes so `W/"abc"`
    /// and `"abc"` compare equal.
    private static func normalise(tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        return value
    }
}

public struct FeedDownloadOutcome: Sendable {
    public var validators: FeedResourceValidators
    public var byteCount: Int64

    public init(validators: FeedResourceValidators, byteCount: Int64) {
        self.validators = validators
        self.byteCount = byteCount
    }
}

/// The seam between the feed manager and the network.
///
/// It exists so the manager can be tested without a server: the install pipeline
/// is the part with the interesting failure modes, and exercising it should not
/// require a socket.
public protocol FeedArchiveProviding: Sendable {
    /// Fetches `url` into `destination`, replacing whatever is there only once
    /// the new bytes are known to be a complete zip archive.
    ///
    /// `progress` is called with (bytes received, total expected); the total is
    /// `0` when the server does not say.
    func downloadArchive(
        from url: URL,
        headers: [String: String],
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> FeedDownloadOutcome

    /// A cheap "has this changed" probe, normally a HEAD. Returning nil means
    /// "could not tell", which callers must treat as "assume it changed".
    ///
    /// The `contentLength` of the result must not be trusted — see
    /// `FeedResourceValidators.matches(_:)`. It is carried only because it is
    /// occasionally a useful hint for a progress bar.
    func validators(for url: URL, headers: [String: String]) async -> FeedResourceValidators?
}

public extension FeedArchiveProviding {
    func validators(for url: URL, headers: [String: String]) async -> FeedResourceValidators? { nil }
}

public enum FeedDownloadError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case emptyResponse
    case notAZipArchive
    case cancelled
    case transport(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The feed server responded with HTTP \(code)."
        case .emptyResponse:
            return "The feed server returned an empty file."
        case .notAZipArchive:
            return "The downloaded file is not a GTFS zip archive."
        case .cancelled:
            return "The download was cancelled."
        case .transport(let reason):
            return reason
        case .fileSystem(let reason):
            return "The download could not be saved: \(reason)"
        }
    }

    /// Whether trying again could plausibly succeed. A 404 will still be a 404;
    /// a dropped connection on a train might not be.
    public var isRetryable: Bool {
        switch self {
        case .transport:
            return true
        case .httpStatus(let code):
            return code == 408 || code == 429 || code >= 500
        case .emptyResponse, .notAZipArchive, .cancelled, .fileSystem:
            return false
        }
    }
}

/// Downloads a GTFS archive with progress, resume, and a check that what arrived
/// is actually a zip.
///
/// The last part matters more than it sounds. Captive portals, expired links and
/// "we've moved" pages all return 200 with an HTML body, and handing that to the
/// importer produces a baffling error several seconds later. Four bytes of local
/// signature check turns it into an honest one immediately.
public final class FeedDownloader: FeedArchiveProviding, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Time allowed between packets, not for the whole transfer.
        public var requestTimeout: TimeInterval = 90
        /// Ceiling for the entire transfer. Generous on purpose: a 90 MB feed
        /// over a weak cellular link legitimately takes many minutes, and the
        /// failure mode worth preventing is a timeout at 60 seconds, not one at
        /// an hour.
        public var resourceTimeout: TimeInterval = 3_600
        public var maximumAttempts: Int = 3
        public var allowsCellularAccess: Bool = true
        /// Let the system hold the request until there is a usable network
        /// instead of failing instantly in a lift.
        public var waitsForConnectivity: Bool = true
        /// Seconds added per retry. Small enough to be invisible, large enough
        /// that a rate-limiting origin gets a moment to breathe.
        public var retryBackoffSeconds: Double = 2
        public var userAgent: String = "MoveIt/1.0 (+GTFS feed downloader)"

        public init() {}
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - FeedArchiveProviding

    public func downloadArchive(
        from url: URL,
        headers: [String: String],
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> FeedDownloadOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(headers, to: &request)

        let staging = destination.appendingPathExtension("part")
        let resumeStore = ResumeDataStore()
        let attempts = max(1, configuration.maximumAttempts)

        for attempt in 0..<attempts {
            if Task.isCancelled { throw FeedDownloadError.cancelled }
            do {
                return try await performDownload(
                    request: request,
                    resumeData: resumeStore.take(),
                    staging: staging,
                    destination: destination,
                    progress: progress,
                    resumeStore: resumeStore
                )
            } catch let error as FeedDownloadError {
                // The staging file is only useful to a resumed transfer, and a
                // resumed transfer carries its own partial data, so it goes.
                try? FileManager.default.removeItem(at: staging)
                guard error.isRetryable, attempt + 1 < attempts else { throw error }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                guard attempt + 1 < attempts else { throw error }
            }

            let seconds = configuration.retryBackoffSeconds * Double(attempt + 1)
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            } catch {
                throw FeedDownloadError.cancelled
            }
        }

        // Unreachable: the final iteration either returns or rethrows.
        throw FeedDownloadError.transport("The download did not complete.")
    }

    public func validators(for url: URL, headers: [String: String]) async -> FeedResourceValidators? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(headers, to: &request)

        let session = URLSession(configuration: makeSessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let found = FeedDownloader.validators(from: http)
            return found.isEmpty ? nil : found
        } catch {
            // A failed HEAD is not worth surfacing: it only means the caller has
            // to download to find out, which is what it would have done anyway.
            return nil
        }
    }

    // MARK: - One attempt

    private func performDownload(
        request: URLRequest,
        resumeData: Data?,
        staging: URL,
        destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        resumeStore: ResumeDataStore
    ) async throws -> FeedDownloadOutcome {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let coordinator = DownloadCoordinator(staging: staging, progress: progress, resumeStore: resumeStore)
        // One session per attempt: the delegate's lifetime is then obvious, and
        // the resume blob belongs to exactly one transfer.
        let session = URLSession(
            configuration: makeSessionConfiguration(),
            delegate: coordinator,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let taskBox = DownloadTaskBox()
        let outcome: DownloadCoordinator.Outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadCoordinator.Outcome, Error>) in
                // Attached before the task is resumed, so no delegate callback can
                // arrive with nothing to resume.
                coordinator.attach(continuation)
                let task: URLSessionDownloadTask
                if let resumeData, !resumeData.isEmpty {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: request)
                }
                taskBox.store(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }

        try FeedDownloader.validateZipSignature(at: staging)
        try FeedDownloader.moveIntoPlace(from: staging, to: destination)
        return FeedDownloadOutcome(validators: outcome.validators, byteCount: outcome.byteCount)
    }

    // MARK: - Helpers

    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/zip, application/octet-stream, */*", forHTTPHeaderField: "Accept")
        }
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.waitsForConnectivity = configuration.waitsForConnectivity
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.allowsExpensiveNetworkAccess = configuration.allowsCellularAccess
        // Low Data Mode is the user saying "not now" to a 90 MB transfer.
        sessionConfiguration.allowsConstrainedNetworkAccess = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The archive is already on disk twice during an install; a third copy in
        // the URL cache would be pure waste.
        sessionConfiguration.urlCache = nil
        return sessionConfiguration
    }

    static func validators(from response: URLResponse?) -> FeedResourceValidators {
        guard let http = response as? HTTPURLResponse else { return FeedResourceValidators() }
        let length = http.expectedContentLength
        return FeedResourceValidators(
            entityTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentLength: length > 0 ? length : nil
        )
    }

    /// The four bytes every zip archive starts with.
    static func validateZipSignature(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FeedDownloadError.fileSystem("the downloaded file disappeared")
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        let bytes = [UInt8](head)
        guard bytes.count == 4 else { throw FeedDownloadError.emptyResponse }
        guard bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 else {
            throw FeedDownloadError.notAZipArchive
        }
    }

    static func moveIntoPlace(from temporary: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw FeedDownloadError.fileSystem(String(describing: error))
        }
    }

    static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

// MARK: - Delegate plumbing

/// Holds the resume blob a failed transfer left behind so the next attempt can
/// pick up where it stopped instead of re-fetching ninety megabytes.
private final class ResumeDataStore: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func store(_ value: Data?) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func take() -> Data? {
        lock.lock()
        let value = data
        data = nil
        lock.unlock()
        return value
    }
}

/// Bridges task cancellation, which can arrive before the download task exists,
/// to the `URLSessionDownloadTask`, which cannot be cancelled before it does.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func store(_ value: URLSessionDownloadTask) {
        lock.lock()
        task = value
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { value.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

/// The `URLSession` delegate for one transfer.
///
/// `didFinishDownloadingTo` hands over a file that the session deletes as soon as
/// the method returns, so the move to the staging path happens inside it rather
/// than after the continuation resumes. Everything else here is bookkeeping to
/// guarantee the continuation is resumed exactly once.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        var validators: FeedResourceValidators
        var byteCount: Int64
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var stagingError: Error?
    private var stagedByteCount: Int64 = 0

    private let staging: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let resumeStore: ResumeDataStore

    init(
        staging: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        resumeStore: ResumeDataStore
    ) {
        self.staging = staging
        self.progress = progress
        self.resumeStore = resumeStore
    }

    func attach(_ continuation: CheckedContinuation<Outcome, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Outcome, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    /// Reports `0` as the total whenever the server's number cannot be believed.
    ///
    /// `NSURLSessionTransferSizeUnknown` is the honest case, but there is a
    /// dishonest one too: origins that advertise a length far smaller than what
    /// they then send. A bar that reaches 100% and keeps filling is worse than no
    /// bar, so an expected total that has already been overtaken is discarded and
    /// the caller shows indeterminate progress instead.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let believable = totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite >= totalBytesWritten
        progress(totalBytesWritten, believable ? totalBytesExpectedToWrite : 0)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: staging.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.moveItem(at: location, to: staging)
            let size = FeedDownloader.fileSize(at: staging)
            lock.lock()
            stagedByteCount = size
            lock.unlock()
        } catch {
            lock.lock()
            stagingError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            if let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeStore.store(resume)
            }
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                finish(.failure(FeedDownloadError.cancelled))
            } else {
                finish(.failure(FeedDownloadError.transport(error.localizedDescription)))
            }
            return
        }

        lock.lock()
        let failure = stagingError
        let byteCount = stagedByteCount
        lock.unlock()

        if let failure {
            finish(.failure(FeedDownloadError.fileSystem(String(describing: failure))))
            return
        }
        // A non-2xx status still "succeeds" as a transfer — the body is just the
        // error page — so the status has to be checked explicitly.
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(FeedDownloadError.httpStatus(http.statusCode)))
            return
        }
        guard byteCount > 0 else {
            finish(.failure(FeedDownloadError.emptyResponse))
            return
        }
        finish(.success(Outcome(validators: FeedDownloader.validators(from: task.response), byteCount: byteCount)))
    }
}
