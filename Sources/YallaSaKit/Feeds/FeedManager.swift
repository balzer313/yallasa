import Foundation

/// Where an install has got to. Reported for the whole operation, not per file,
/// because that is the only thing the user can act on.
public enum FeedInstallStage: String, Sendable, Hashable, CaseIterable, Codable {
    case downloading, compiling, installing, done
}

public struct FeedInstallProgress: Sendable, Equatable {
    public var stage: FeedInstallStage
    /// 0...1 across the whole install. Download and compile are weighted
    /// `FeedManager.downloadProgressWeight` / `.compileProgressWeight`.
    public var fraction: Double
    public var detail: String
    public var bytesDownloaded: Int64
    /// `0` when the server did not say, or said something implausible. The UI
    /// must show an indeterminate bar in that case rather than dividing by it.
    public var totalBytes: Int64

    public init(
        stage: FeedInstallStage,
        fraction: Double,
        detail: String = "",
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0
    ) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
        self.detail = detail
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
    }

    public var isIndeterminate: Bool { stage == .downloading && totalBytes <= 0 }
}

public enum FeedManagerError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case graphMissing(String)
    case archiveMissing(String)
    case directoryUnavailable(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let identifier):
            return "No feed with identifier \(identifier) is installed."
        case .graphMissing(let identifier):
            return "The compiled data for \(identifier) is missing; the feed needs reinstalling."
        case .archiveMissing(let identifier):
            return "The cached download for \(identifier) is no longer on disk."
        case .directoryUnavailable(let reason):
            return "The feed folder could not be prepared: \(reason)"
        case .fileSystem(let reason):
            return reason
        }
    }
}

/// The seam between the feed manager and the GTFS importer.
///
/// Same reason as `FeedArchiveProviding`: the install pipeline's interesting
/// behaviour is what it does when a compile fails, and proving that should not
/// require a real feed and thirty seconds of CPU.
public protocol FeedGraphCompiling: Sendable {
    func compile(
        archiveAt archive: URL,
        to destination: URL,
        options: GTFSImportOptions,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (GTFSImportProgress) -> Void
    ) throws -> GraphMetadata
}

/// The production compiler: a thin adapter over `GTFSImporter`.
public struct GTFSGraphCompiler: FeedGraphCompiling {
    public init() {}

    public func compile(
        archiveAt archive: URL,
        to destination: URL,
        options: GTFSImportOptions,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (GTFSImportProgress) -> Void
    ) throws -> GraphMetadata {
        let importer = GTFSImporter(options: options)
        importer.isCancelled = isCancelled
        importer.onProgress = progress
        return try importer.compile(archiveAt: archive, to: destination)
    }
}

/// Owns everything on disk that came from a feed: the downloaded archives, the
/// compiled graphs, and the manifest that says which is which.
///
/// ## Why an actor
///
/// Installing, refreshing and removing all mutate the same directory, and the UI
/// can trigger any of them at any moment. Serialising them through an actor is
/// the difference between "two installs of the same feed race and one of them
/// deletes the other's graph" and "the second one waits". The expensive part —
/// the compile — is explicitly pushed off the actor onto a detached task, so a
/// twenty-second import does not block a departure-board query that only wants to
/// read `installedFeeds`.
///
/// ## Atomicity
///
/// The manifest is the source of truth, and it is written last. Every install
/// therefore follows: download to `<archive>.part` and rename on success →
/// compile to `<graph>.tmp` → rename the graph into place → rewrite the manifest
/// → only then delete the graph the manifest used to point at. A crash at any
/// point leaves the previous manifest, which still points at a graph that still
/// exists. The worst case is an orphaned temp file.
public actor FeedManager {
    /// Download is 40% of the reported progress and compile the other 60%. It is
    /// a guess, but a well-founded one: on a phone, compiling a metro feed takes
    /// appreciably longer than fetching it over Wi-Fi and appreciably less than
    /// fetching it over a weak cellular link.
    public static let downloadProgressWeight = 0.4
    public static let compileProgressWeight = 0.6

    public static let archivesDirectoryName = "archives"
    public static let graphsDirectoryName = "graphs"

    private let directory: URL
    private let archivesDirectory: URL
    private let graphsDirectory: URL
    private let manifestURL: URL
    private let archiveProvider: any FeedArchiveProviding
    private let compiler: any FeedGraphCompiling

    /// Defaulted so the initialiser is free to throw while preparing the
    /// directories: a designated initialiser may not throw with a stored property
    /// still uninitialised.
    private var manifest = FeedManifest()
    /// The graph opened by `activate`. Held so repeated activations do not remap
    /// the file, and dropped whenever the file underneath it is replaced.
    private var openGraph: TransitGraph?

    /// `archiveProvider` and `compiler` have defaults, so the contract's
    /// `init(directory:)` is what the app calls and the tests get their seams.
    public init(
        directory: URL,
        archiveProvider: any FeedArchiveProviding = FeedDownloader(),
        compiler: any FeedGraphCompiling = GTFSGraphCompiler()
    ) throws {
        self.directory = directory
        self.archivesDirectory = directory.appendingPathComponent(
            FeedManager.archivesDirectoryName, isDirectory: true
        )
        self.graphsDirectory = directory.appendingPathComponent(
            FeedManager.graphsDirectoryName, isDirectory: true
        )
        self.manifestURL = directory.appendingPathComponent(FeedManifest.fileName, isDirectory: false)
        self.archiveProvider = archiveProvider
        self.compiler = compiler

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: self.archivesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: self.graphsDirectory, withIntermediateDirectories: true)
        } catch {
            throw FeedManagerError.directoryUnavailable(String(describing: error))
        }

        self.manifest = FeedManifest.loadOrEmpty(from: self.manifestURL)
    }

    // MARK: - State

    /// Installed feeds, with each source refreshed against the current catalogue.
    ///
    /// The manifest persists a whole `FeedSource`, which was written by whatever
    /// build performed the install. Anything the app later *learns* about a feed
    /// — a realtime endpoint, a live-positions service — is therefore invisible
    /// on every existing installation until the rider deletes and reinstalls,
    /// and nothing tells them to.
    ///
    /// That is not hypothetical: live vehicle positions shipped after the first
    /// builds, so every feed installed before them reported `vehiclePositions`
    /// nil and the map stayed empty for good.
    ///
    /// The rider's own choices — which URL, which clip box — stay as installed,
    /// because those describe the graph actually on disk. Only the fields the
    /// catalogue owns are refreshed.
    public var installedFeeds: [InstalledFeed] {
        manifest.feeds.map { feed in
            var updated = feed
            updated.source = feed.source.refreshedFromCatalog()
            return updated
        }
    }

    public var activeFeedID: String? { manifest.activeFeedID }

    /// The currently open graph, if `activate` has been called this session.
    public var currentGraph: TransitGraph? { openGraph }

    public func feed(withID identifier: String) -> InstalledFeed? { manifest.feed(withID: identifier) }

    public func installRecord(forFeedID identifier: String) -> FeedInstallRecord? {
        manifest.installRecords[identifier]
    }

    /// Bytes used by everything under the feed directory, archives included.
    public var diskUsage: Int64 { FeedManager.directorySize(at: directory) }

    /// Bytes used by cached archives alone — the part that is safe to delete.
    public var archiveDiskUsage: Int64 { FeedManager.directorySize(at: archivesDirectory) }

    // MARK: - Install

    public func install(
        _ source: FeedSource,
        region: GeoBounds?,
        progress: @Sendable @escaping (FeedInstallProgress) -> Void
    ) async throws -> InstalledFeed {
        try Task.checkCancellation()

        let archiveURL = archiveFileURL(forFeedID: source.id)
        let estimate = source.estimatedDownloadBytes
        let relay = DownloadProgressRelay(estimatedTotalBytes: estimate, sink: progress)

        progress(
            FeedInstallProgress(
                stage: .downloading,
                fraction: 0,
                detail: "Fetching \(source.name)",
                bytesDownloaded: 0,
                totalBytes: estimate
            )
        )

        let outcome = try await archiveProvider.downloadArchive(
            from: source.staticURL,
            headers: source.requestHeaders,
            to: archiveURL
        ) { received, total in
            relay.report(bytes: received, total: total)
        }

        return try await compileAndPublish(
            source: source,
            region: region,
            archiveURL: archiveURL,
            archiveByteCount: outcome.byteCount,
            validators: outcome.validators,
            downloadedAt: Date(),
            progress: progress
        )
    }

    /// Everything after the bytes are on disk. Shared by `install`,
    /// `refreshIfNeeded` and `recompileIfFormatChanged`, so all three get the same
    /// atomicity guarantees.
    private func compileAndPublish(
        source: FeedSource,
        region: GeoBounds?,
        archiveURL: URL,
        archiveByteCount: Int64,
        validators: FeedResourceValidators,
        downloadedAt: Date,
        progress: @Sendable @escaping (FeedInstallProgress) -> Void
    ) async throws -> InstalledFeed {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw FeedManagerError.archiveMissing(source.id)
        }

        // Milliseconds, so two installs in the same second cannot collide on a
        // file name and silently share a graph.
        let stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let graphFileName = "\(FeedManager.fileSafe(source.id))-\(stamp).mvtg"
        let finalGraphURL = graphsDirectory.appendingPathComponent(graphFileName, isDirectory: false)
        let temporaryGraphURL = graphsDirectory.appendingPathComponent(
            graphFileName + ".tmp", isDirectory: false
        )

        var options = GTFSImportOptions(
            feedIdentifier: source.id,
            feedName: source.name,
            sourceURL: source.staticURL.absoluteString
        )
        options.boundingBox = region ?? source.defaultBoundingBox
        let resolvedRegion = options.boundingBox

        let downloadWeight = FeedManager.downloadProgressWeight
        let compileWeight = FeedManager.compileProgressWeight
        progress(
            FeedInstallProgress(
                stage: .compiling,
                fraction: downloadWeight,
                detail: "Reading \(source.name)",
                bytesDownloaded: archiveByteCount,
                totalBytes: archiveByteCount
            )
        )

        let throttle = CompileProgressThrottle()
        let metadata: GraphMetadata
        do {
            metadata = try await FeedManager.runCompile(
                compiler: compiler,
                archive: archiveURL,
                destination: temporaryGraphURL,
                options: options
            ) { importProgress in
                let overall = min(1, max(0, importProgress.overallFraction))
                guard throttle.shouldEmit(overall) else { return }
                progress(
                    FeedInstallProgress(
                        stage: .compiling,
                        fraction: downloadWeight + compileWeight * overall,
                        detail: importProgress.detail.isEmpty
                            ? importProgress.phase.rawValue
                            : importProgress.detail,
                        bytesDownloaded: archiveByteCount,
                        totalBytes: archiveByteCount
                    )
                )
            }
        } catch {
            // The importer promises to remove `destination` on throw; belt and
            // braces, because a stale `.tmp` would be published by a later run
            // that happened to pick the same name.
            try? fileManager.removeItem(at: temporaryGraphURL)
            throw error
        }

        progress(
            FeedInstallProgress(
                stage: .installing,
                fraction: downloadWeight + compileWeight * 0.98,
                detail: "Finishing up",
                bytesDownloaded: archiveByteCount,
                totalBytes: archiveByteCount
            )
        )

        do {
            try FeedManager.moveIntoPlace(from: temporaryGraphURL, to: finalGraphURL)
        } catch {
            try? fileManager.removeItem(at: temporaryGraphURL)
            throw FeedManagerError.fileSystem(String(describing: error))
        }

        let installed = InstalledFeed(
            id: source.id,
            source: source,
            graphFileName: graphFileName,
            installedAt: Date(),
            metadata: metadata,
            byteSize: FeedManager.fileSize(at: finalGraphURL)
        )

        let previous = manifest.feed(withID: source.id)
        var updated = manifest
        if let index = updated.feeds.firstIndex(where: { $0.id == source.id }) {
            updated.feeds[index] = installed
        } else {
            updated.feeds.append(installed)
        }
        updated.installRecords[source.id] = FeedInstallRecord(
            entityTag: validators.entityTag,
            lastModified: validators.lastModified,
            contentLength: validators.contentLength,
            checkedAt: Date(),
            downloadedAt: downloadedAt,
            region: resolvedRegion,
            archiveFileName: archiveURL.lastPathComponent,
            archiveByteSize: archiveByteCount
        )

        do {
            try updated.save(to: manifestURL)
        } catch {
            // Nothing references the new graph, so it is dead weight rather than
            // a half-installed feed. The previous manifest is untouched.
            try? fileManager.removeItem(at: finalGraphURL)
            throw error
        }
        manifest = updated

        // Only now is the old graph unreachable from the manifest.
        if let previous, previous.graphFileName != graphFileName {
            try? fileManager.removeItem(
                at: graphsDirectory.appendingPathComponent(previous.graphFileName, isDirectory: false)
            )
        }
        // Force a remap on next activate; the open one points at the old file.
        if manifest.activeFeedID == source.id { openGraph = nil }

        progress(
            FeedInstallProgress(
                stage: .done,
                fraction: 1,
                detail: "Ready",
                bytesDownloaded: archiveByteCount,
                totalBytes: archiveByteCount
            )
        )
        return installed
    }

    // MARK: - Activate

    public func activate(_ feedID: String) async throws -> TransitGraph {
        guard let feed = manifest.feed(withID: feedID) else {
            throw FeedManagerError.notInstalled(feedID)
        }
        if let openGraph, manifest.activeFeedID == feedID {
            return openGraph
        }

        let url = graphsDirectory.appendingPathComponent(feed.graphFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FeedManagerError.graphMissing(feedID)
        }

        let graph = try TransitGraph.open(contentsOf: url)
        openGraph = graph
        if manifest.activeFeedID != feedID {
            var updated = manifest
            updated.activeFeedID = feedID
            try updated.save(to: manifestURL)
            manifest = updated
        }
        return graph
    }

    /// Reopens whatever was active last launch. Returns nil when nothing was, or
    /// when the recorded feed can no longer be opened — the caller then shows the
    /// feed picker instead of an error nobody can act on.
    public func activateRecordedFeed() async -> TransitGraph? {
        guard let identifier = manifest.activeFeedID else { return nil }
        return try? await activate(identifier)
    }

    // MARK: - Remove

    public func remove(_ feedID: String) async throws {
        guard let index = manifest.feeds.firstIndex(where: { $0.id == feedID }) else {
            throw FeedManagerError.notInstalled(feedID)
        }
        let feed = manifest.feeds[index]
        let wasActive = manifest.activeFeedID == feedID

        var updated = manifest
        updated.feeds.remove(at: index)
        updated.installRecords[feedID] = nil
        if wasActive {
            // Never leave the active id pointing at something that is gone. If
            // another feed is still installed, fall to it rather than dropping the
            // app back to its empty state.
            updated.activeFeedID = updated.feeds.first?.id
        }

        // Manifest first: after this point the files are unreferenced, so failing
        // to delete them costs disk space and nothing else.
        try updated.save(to: manifestURL)
        manifest = updated
        if wasActive { openGraph = nil }

        let fileManager = FileManager.default
        try? fileManager.removeItem(
            at: graphsDirectory.appendingPathComponent(feed.graphFileName, isDirectory: false)
        )
        try? fileManager.removeItem(at: archiveFileURL(forFeedID: feedID))
    }

    // MARK: - Refresh

    /// Re-downloads and recompiles `feedID` if its graph is older than
    /// `maximumAge` *and* the server's copy has actually changed.
    ///
    /// The revalidation step is strictly an optimisation and is treated as such:
    /// a server that does not answer a HEAD, or answers without an `ETag` or
    /// `Last-Modified`, falls through to a plain re-download. It can never make
    /// the manager skip an update — only skip a redundant one.
    @discardableResult
    public func refreshIfNeeded(
        _ feedID: String,
        maximumAge: TimeInterval,
        progress: @Sendable @escaping (FeedInstallProgress) -> Void
    ) async throws -> Bool {
        guard let feed = manifest.feed(withID: feedID) else {
            throw FeedManagerError.notInstalled(feedID)
        }
        let record = manifest.installRecords[feedID]
        let referenceDate = record?.downloadedAt ?? feed.installedAt
        guard Date().timeIntervalSince(referenceDate) >= maximumAge else { return false }

        if let record {
            let known = record.validators
            if !known.isEmpty,
               let current = await archiveProvider.validators(
                   for: feed.source.staticURL,
                   headers: feed.source.requestHeaders
               ),
               current.matches(known) {
                // Same archive upstream. Stamp the check so the next call waits a
                // full `maximumAge` before asking again, and skip the compile
                // entirely — which is the whole point of the HEAD.
                var updated = manifest
                updated.installRecords[feedID]?.checkedAt = Date()
                updated.installRecords[feedID]?.downloadedAt = Date()
                try updated.save(to: manifestURL)
                manifest = updated
                progress(FeedInstallProgress(stage: .done, fraction: 1, detail: "Already up to date"))
                return false
            }
        }

        _ = try await install(feed.source, region: record?.region, progress: progress)
        return true
    }

    /// Rebuilds any installed graph written by an older format version, using the
    /// archive already on disk.
    ///
    /// This is the reason archives are kept at all: a format bump is our decision,
    /// not the user's, and making them re-download 141 MB because we changed a
    /// column layout would be indefensible. A feed whose archive has been pruned
    /// is skipped and left for a normal refresh to fix.
    public func recompileIfFormatChanged() async throws {
        let stale = manifest.feeds.filter { $0.needsRecompile }
        guard !stale.isEmpty else { return }

        for feed in stale {
            let archiveURL = archiveFileURL(forFeedID: feed.id)
            guard FileManager.default.fileExists(atPath: archiveURL.path) else { continue }
            let record = manifest.installRecords[feed.id]
            _ = try await compileAndPublish(
                source: feed.source,
                region: record?.region,
                archiveURL: archiveURL,
                archiveByteCount: FeedManager.fileSize(at: archiveURL),
                validators: record?.validators ?? FeedResourceValidators(),
                downloadedAt: record?.downloadedAt ?? feed.installedAt,
                progress: { _ in }
            )
        }
    }

    // MARK: - Disk budget

    /// Deletes cached archives, oldest first, until they fit in `keepingBytes`.
    /// Returns the number of bytes freed.
    ///
    /// Graphs are never touched. An archive is a cache that costs a download to
    /// rebuild; a graph is the feed itself, and deleting one to save space would
    /// take away the offline timetable the user installed the app for.
    @discardableResult
    public func pruneArchives(keepingBytes budget: Int64) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let contents = (try? fileManager.contentsOfDirectory(
            at: archivesDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        var entries: [(url: URL, size: Int64, modified: Date)] = []
        for url in contents where url.pathExtension.lowercased() == "zip" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            entries.append(
                (
                    url: url,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? Date.distantPast
                )
            )
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > budget else { return 0 }

        entries.sort { $0.modified < $1.modified }
        var freed: Int64 = 0
        for entry in entries {
            if total <= budget { break }
            do {
                try fileManager.removeItem(at: entry.url)
            } catch {
                continue
            }
            total -= entry.size
            freed += entry.size
        }
        return freed
    }

    /// Deletes graph files and archives no manifest entry refers to. Cheap
    /// insurance against a crash between a rename and a manifest write.
    @discardableResult
    public func removeOrphanedFiles() -> Int {
        let fileManager = FileManager.default
        let referencedGraphs = Set(manifest.feeds.map { $0.graphFileName })
        let referencedArchives = Set(manifest.feeds.map { archiveFileURL(forFeedID: $0.id).lastPathComponent })

        var removed = 0
        let graphFiles = (try? fileManager.contentsOfDirectory(
            at: graphsDirectory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]
        )) ?? []
        for url in graphFiles where !referencedGraphs.contains(url.lastPathComponent) {
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }

        let archiveFiles = (try? fileManager.contentsOfDirectory(
            at: archivesDirectory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]
        )) ?? []
        for url in archiveFiles where !referencedArchives.contains(url.lastPathComponent) {
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Paths

    public func archiveFileURL(forFeedID identifier: String) -> URL {
        archivesDirectory.appendingPathComponent(
            "\(FeedManager.fileSafe(identifier)).zip", isDirectory: false
        )
    }

    public func graphFileURL(for feed: InstalledFeed) -> URL {
        graphsDirectory.appendingPathComponent(feed.graphFileName, isDirectory: false)
    }

    // MARK: - Static helpers
    //
    // Static so they can be used from detached tasks and delegate callbacks
    // without dragging actor isolation along.

    /// Runs the importer off the actor.
    ///
    /// A compile is seconds to minutes of solid CPU. Doing it inside the actor
    /// would make every `installedFeeds` read wait for it, which is exactly the
    /// stall the UI would notice.
    private static func runCompile(
        compiler: any FeedGraphCompiling,
        archive: URL,
        destination: URL,
        options: GTFSImportOptions,
        progress: @escaping @Sendable (GTFSImportProgress) -> Void
    ) async throws -> GraphMetadata {
        let work = Task.detached(priority: .userInitiated) { () throws -> GraphMetadata in
            try compiler.compile(
                archiveAt: archive,
                to: destination,
                options: options,
                isCancelled: { Task.isCancelled },
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func moveIntoPlace(from temporary: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Feed identifiers are catalogue data and user input, and both end up in file
    /// names. Anything outside a conservative set becomes an underscore.
    static func fileSafe(_ identifier: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let mapped = String(identifier.map { allowed.contains($0) ? $0 : "_" })
        let trimmed = String(mapped.prefix(80))
        return trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) ? "feed" : trimmed
    }
}

// MARK: - Progress relays

/// Turns the download delegate's firehose into something a UI can bind to.
///
/// `didWriteData` fires per network chunk — thousands of times for a 141 MB
/// archive — and forwarding all of it would spend more time hopping to the main
/// actor than downloading. Emission is gated on a visible change.
private final class DownloadProgressRelay: @unchecked Sendable {
    private static let byteStep: Int64 = 262_144
    private static let fractionStep = 0.005

    private let lock = NSLock()
    private var lastBytes: Int64 = -1
    private var lastFraction: Double = -1

    private let estimatedTotalBytes: Int64
    private let sink: @Sendable (FeedInstallProgress) -> Void

    init(estimatedTotalBytes: Int64, sink: @escaping @Sendable (FeedInstallProgress) -> Void) {
        self.estimatedTotalBytes = estimatedTotalBytes
        self.sink = sink
    }

    func report(bytes: Int64, total: Int64) {
        // `total` is 0 when the server did not say or said something already
        // overtaken. The catalogue estimate stands in, and is itself discarded
        // once the transfer passes it — better an indeterminate bar than one that
        // claims to be finished twice.
        let effectiveTotal: Int64
        if total > 0, total >= bytes {
            effectiveTotal = total
        } else if estimatedTotalBytes > 0, estimatedTotalBytes >= bytes {
            effectiveTotal = estimatedTotalBytes
        } else {
            effectiveTotal = 0
        }

        let ratio = effectiveTotal > 0 ? min(1, Double(bytes) / Double(effectiveTotal)) : 0

        lock.lock()
        let shouldEmit = bytes - lastBytes >= DownloadProgressRelay.byteStep
            || ratio - lastFraction >= DownloadProgressRelay.fractionStep
        if shouldEmit {
            lastBytes = bytes
            lastFraction = ratio
        }
        lock.unlock()
        guard shouldEmit else { return }

        sink(
            FeedInstallProgress(
                stage: .downloading,
                fraction: ratio * FeedManager.downloadProgressWeight,
                detail: FeedManager.describeTransfer(received: bytes, total: effectiveTotal),
                bytesDownloaded: bytes,
                totalBytes: effectiveTotal
            )
        )
    }
}

/// Same idea for the importer, which reports far more often than a progress bar
/// can usefully redraw.
private final class CompileProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1

    func shouldEmit(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction - last >= 0.002 || fraction >= 1 else { return false }
        last = fraction
        return true
    }
}

extension FeedManager {
    /// "12.4 MB of 141 MB", or just "12.4 MB" when the total is unknown. Built by
    /// hand rather than with `ByteCountFormatter` because this runs on the
    /// download delegate's queue several times a second.
    static func describeTransfer(received: Int64, total: Int64) -> String {
        let receivedText = describe(bytes: received)
        guard total > 0 else { return receivedText }
        return "\(receivedText) of \(describe(bytes: total))"
    }

    static func describe(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return String(format: "%.1f MB", megabytes)
    }
}
