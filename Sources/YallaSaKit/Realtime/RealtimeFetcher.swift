import Foundation
#if canImport(os)
import os
#endif

/// Polls an agency's GTFS-Realtime endpoints and publishes resolved snapshots.
///
/// An actor because the polling loop, a manual pull-to-refresh and the app going
/// to the background all reach for the same state, and because the HTTP
/// validators it keeps are exactly the kind of thing that goes wrong when two
/// callers race.
///
/// The important behaviour is what it does when the network misbehaves, which on
/// a phone is most of the time: **nothing that happens to a fetch is allowed to
/// end the poll loop or discard the snapshot already in hand**. A timeout, a
/// captive portal, a 500, a body that is not protobuf — all of them leave
/// `current` alone, log, and back off. A rider on a train through a tunnel keeps
/// the predictions they had.
public actor RealtimeFetcher {

    /// Cached body and validators for one endpoint. The body is kept because the
    /// two endpoints are fetched independently but produce one merged snapshot:
    /// when alerts answer 304 and trip updates do not, the snapshot still needs
    /// the alerts.
    private struct EndpointCache {
        var entityTag: String?
        var lastModified: String?
        var body: Data?
    }

    private let graph: TransitGraph
    private let lookup: RealtimeTripLookup
    private let tripUpdatesURL: URL?
    private let alertsURL: URL?
    private let headers: [String: String]
    private let session: URLSession

    private var caches: [URL: EndpointCache] = [:]
    private var pollingTask: Task<Void, Never>?

    /// The most recent snapshot that resolved successfully, or nil before the
    /// first one lands.
    public private(set) var current: RealtimeIndex?

    /// Why the last refresh produced nothing, for a diagnostics screen. Not an
    /// error to act on — the fetcher has already decided to retry.
    public private(set) var lastFailureDescription: String?

    /// Consecutive failed refreshes, which drives the backoff.
    public private(set) var consecutiveFailureCount: Int = 0

    /// A body larger than this is not a realtime feed; it is an error page, a
    /// redirect loop, or something hostile. The largest real trip-updates feeds
    /// are a few megabytes.
    private static let maximumBodyBytes = 32 * 1024 * 1024

    public init(
        graph: TransitGraph,
        tripUpdatesURL: URL?,
        alertsURL: URL?,
        headers: [String: String],
        lookup: RealtimeTripLookup
    ) {
        self.graph = graph
        self.lookup = lookup
        self.tripUpdatesURL = tripUpdatesURL
        self.alertsURL = alertsURL
        self.headers = headers

        let configuration = URLSessionConfiguration.ephemeral
        // Realtime is worthless late. A request that has not answered in ten
        // seconds has missed its window; the next poll is already due.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        // Freshness is managed here with explicit validators rather than by
        // URLCache, so that a 304 can be turned into "keep the current snapshot"
        // instead of being invisibly replayed from disk.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Refresh

    /// Fetches every configured endpoint and, if anything changed, resolves a new
    /// snapshot against the graph.
    ///
    /// Returns nil — rather than throwing — when there is nothing new: no URLs
    /// configured, every endpoint answered 304, or the fetch failed. `current` is
    /// untouched in all three cases. The `throws` remains on the signature for
    /// genuinely unexpected states; ordinary network weather is not one.
    @discardableResult
    public func refresh() async throws -> RealtimeIndex? {
        var urls: [URL] = []
        if let primary = tripUpdatesURL {
            urls.append(primary)
        }
        if let secondary = alertsURL, secondary != tripUpdatesURL {
            urls.append(secondary)
        }
        guard !urls.isEmpty else { return nil }

        var feed = GTFSRealtimeFeed(generatedAt: .distantPast)
        var anythingChanged = false
        var anythingUsable = false
        var failure: String?

        for url in urls {
            let outcome = await fetch(url)
            switch outcome {
            case .unchanged(let body):
                guard let body else { continue }
                if let decoded = decodeOrLog(body, from: url) {
                    feed = feed.merging(decoded)
                    anythingUsable = true
                }
            case .changed(let body):
                anythingChanged = true
                if let decoded = decodeOrLog(body, from: url) {
                    feed = feed.merging(decoded)
                    anythingUsable = true
                }
            case .failed(let reason):
                failure = reason
            }
        }

        guard anythingChanged, anythingUsable else {
            if let failure {
                consecutiveFailureCount += 1
                lastFailureDescription = failure
            } else {
                // Everything answered 304: the feed is healthy and unchanged.
                consecutiveFailureCount = 0
                lastFailureDescription = nil
            }
            return nil
        }

        if feed.generatedAt == .distantPast { feed.generatedAt = Date() }

        let referenceDate = ServiceDate(date: feed.generatedAt, in: graph.timeZone)
        let index = RealtimeIndex(
            feed: feed,
            graph: graph,
            referenceDate: referenceDate,
            lookup: lookup
        )
        current = index
        consecutiveFailureCount = 0
        lastFailureDescription = nil
        return index
    }

    private enum FetchOutcome {
        /// 304, or a 200 whose body is byte-identical to the last one.
        case unchanged(Data?)
        case changed(Data)
        case failed(String)
    }

    private func fetch(_ url: URL) async -> FetchOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let cache = caches[url]
        if let entityTag = cache?.entityTag {
            request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cache?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log("Realtime fetch of \(url.absoluteString) failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed("Non-HTTP response")
        }

        if http.statusCode == 304 {
            return .unchanged(cache?.body)
        }
        guard (200...299).contains(http.statusCode) else {
            log("Realtime fetch of \(url.absoluteString) returned HTTP \(http.statusCode)")
            return .failed("HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            return .failed("Empty response body")
        }
        guard data.count <= RealtimeFetcher.maximumBodyBytes else {
            log("Realtime body from \(url.absoluteString) is \(data.count) bytes; refusing it")
            return .failed("Response too large")
        }

        var updated = cache ?? EndpointCache()
        updated.entityTag = http.value(forHTTPHeaderField: "ETag")
        updated.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let isIdentical = updated.body == data
        updated.body = data
        caches[url] = updated

        // Plenty of producers serve no validators at all and republish the same
        // bytes every few seconds; comparing them avoids rebuilding an identical
        // index and re-rendering every departure board behind it.
        return isIdentical ? .unchanged(data) : .changed(data)
    }

    private func decodeOrLog(_ body: Data, from url: URL) -> GTFSRealtimeFeed? {
        do {
            return try GTFSRealtimeDecoder.decode(body)
        } catch {
            log("Realtime body from \(url.absoluteString) is not a valid feed: \(error)")
            lastFailureDescription = "Malformed realtime feed"
            return nil
        }
    }

    // MARK: - Polling

    /// Refreshes every `interval` seconds until `stopPolling`, calling `onUpdate`
    /// each time a genuinely new snapshot lands.
    ///
    /// Backs off exponentially while the network is failing, up to five minutes,
    /// and resets the moment a fetch succeeds. Hammering an agency's endpoint
    /// every fifteen seconds through an outage is how a free feed stops being
    /// free for everybody.
    public func startPolling(interval: TimeInterval, onUpdate: @Sendable @escaping (RealtimeIndex) -> Void) {
        stopPolling()
        let base = max(10, interval)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.tick()
                if let index = outcome.index {
                    onUpdate(index)
                }
                let delay = RealtimeFetcher.backoffDelay(base: base, failures: outcome.failures)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return   // cancelled while sleeping
                }
            }
        }
    }

    /// One poll: refresh, and report back the failure count the loop needs to
    /// pick its next delay. Bundled into a single actor hop so the loop never
    /// reads state that changed between two awaits.
    private func tick() async -> (index: RealtimeIndex?, failures: Int) {
        let index = try? await refresh()
        return (index: index, failures: consecutiveFailureCount)
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Doubles per consecutive failure, capped at five minutes.
    static func backoffDelay(base: TimeInterval, failures: Int) -> TimeInterval {
        guard failures > 0 else { return base }
        let exponent = min(failures, 5)
        let scaled = base * pow(2, Double(exponent))
        return min(scaled, 300)
    }

    /// Drops the cached validators so the next refresh re-fetches in full. Used
    /// when the graph is replaced under us and the old snapshot's indices no
    /// longer mean anything.
    public func invalidate() {
        caches.removeAll()
        current = nil
        consecutiveFailureCount = 0
        lastFailureDescription = nil
    }

    private nonisolated func log(_ message: String) {
        #if canImport(os)
        RealtimeFetcher.logger.error("\(message, privacy: .public)")
        #endif
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.yallasa.YallaSaKit", category: "realtime")
    #endif
}
