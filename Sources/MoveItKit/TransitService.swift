import Foundation
import Combine

public enum TransitServiceState: Equatable, Sendable {
    case idle
    /// No feed installed yet — the app shows the feed picker.
    case needsFeed
    case installing
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }
}

public enum TransitServiceError: Error, LocalizedError, Equatable {
    case noActiveFeed
    case feedNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveFeed:
            return "No timetable is loaded yet."
        case .feedNotInstalled(let id):
            return "The feed \(id) is not installed."
        }
    }
}

/// The one object the app talks to.
///
/// Everything below this line is engine: a memory-mapped graph, a RAPTOR router,
/// a realtime overlay. Everything above it is SwiftUI. Keeping that boundary
/// narrow is what lets the engine be tested without a UI and the UI be built
/// against a fake without a feed.
///
/// The service is `@MainActor` because it publishes to SwiftUI, but no routing
/// ever runs on the main actor: queries are dispatched to a private serial queue
/// and only their results come back. A journey plan on a large feed is tens of
/// milliseconds of tight array scanning, which is exactly the kind of work that
/// makes a scroll stutter if you let it near the main thread.
@MainActor
public final class TransitService: ObservableObject {
    public static let shared = TransitService()

    @Published public private(set) var state: TransitServiceState = .idle
    @Published public private(set) var installProgress: FeedInstallProgress?
    @Published public private(set) var installedFeeds: [InstalledFeed] = []
    @Published public private(set) var activeFeed: InstalledFeed?
    @Published public private(set) var realtimeUpdatedAt: Date?
    /// Alerts from the current realtime snapshot, for the banner on Nearby.
    @Published public private(set) var alerts: [ServiceAlert] = []

    public private(set) var graph: TransitGraph?
    public private(set) var searchIndex: StopSearchIndex?

    private var feedManager: FeedManager?
    private var engine: Engine?
    private var realtimeFetcher: RealtimeFetcher?
    private var realtimeLookup: RealtimeTripLookup?
    private var pollingTask: Task<Void, Never>?

    private let workQueue = DispatchQueue(
        label: "app.moveit.engine",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// The immutable bundle a query needs. Snapshotted per call so a feed swap
    /// mid-query cannot pull the graph out from under a running search.
    private struct Engine: @unchecked Sendable {
        let graph: TransitGraph
        let planner: JourneyPlanner
        let board: DepartureBoardService
        var realtime: RealtimeSource
    }

    private init() {}

    // MARK: - Lifecycle

    /// Opens the feed store and activates the last-used feed. Safe to call more
    /// than once; later calls are no-ops once a feed is live.
    public func bootstrap() async {
        switch state {
        case .idle, .failed:
            break
        case .needsFeed, .installing, .ready:
            return
        }
        do {
            let directory = try TransitService.feedDirectory()
            let manager = try FeedManager(directory: directory)
            self.feedManager = manager

            let feeds = await manager.installedFeeds
            self.installedFeeds = feeds

            if let activeID = await manager.activeFeedID, feeds.contains(where: { $0.id == activeID }) {
                try await activate(feedID: activeID)
            } else if let first = feeds.first {
                try await activate(feedID: first.id)
            } else {
                state = .needsFeed
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public var timeZone: TimeZone { graph?.timeZone ?? .current }

    /// "Now" in the frame the engine reasons in.
    public func currentInstant() -> ServiceInstant {
        ServiceInstant(date: Date(), in: timeZone)
    }

    // MARK: - Feeds

    public func install(_ source: FeedSource, region: GeoBounds? = nil) async throws {
        guard let feedManager else { throw TransitServiceError.noActiveFeed }
        state = .installing
        installProgress = FeedInstallProgress(
            stage: .downloading, fraction: 0, detail: "Starting…", bytesDownloaded: 0, totalBytes: 0
        )
        defer { installProgress = nil }

        do {
            // The weak capture belongs on the inner `Task`, not the outer
            // closure. Capturing it outside leaves the nested, concurrently
            // executing closure reading a captured mutable optional, which the
            // concurrency checker rejects outright.
            let installed = try await feedManager.install(source, region: region) { progress in
                Task { @MainActor [weak self] in self?.installProgress = progress }
            }
            installedFeeds = await feedManager.installedFeeds
            try await activate(feedID: installed.id)
        } catch {
            // A failed install must not strand the app: if a feed was already
            // live, keep using it and surface the error separately.
            state = graph == nil ? .needsFeed : .ready
            throw error
        }
    }

    public func activate(feedID: String) async throws {
        guard let feedManager else { throw TransitServiceError.noActiveFeed }
        stopRealtimePolling()

        let newGraph = try await feedManager.activate(feedID)
        let feeds = await feedManager.installedFeeds
        guard let feed = feeds.first(where: { $0.id == feedID }) else {
            throw TransitServiceError.feedNotInstalled(feedID)
        }

        newGraph.warmUp()

        self.graph = newGraph
        self.activeFeed = feed
        self.installedFeeds = feeds
        self.engine = Engine(
            graph: newGraph,
            planner: JourneyPlanner(graph: newGraph),
            board: DepartureBoardService(graph: newGraph),
            realtime: EmptyRealtimeSource.shared
        )
        self.realtimeLookup = nil
        self.realtimeFetcher = nil
        self.realtimeUpdatedAt = nil
        self.alerts = []
        self.state = .ready

        // Search and realtime id lookups both need a full pass over the graph, so
        // they are built off the main actor after the UI is already usable.
        buildAuxiliaryIndexes(for: newGraph, feed: feed)
    }

    public func removeFeed(id: String) async throws {
        guard let feedManager else { return }
        if activeFeed?.id == id {
            stopRealtimePolling()
            graph = nil
            engine = nil
            searchIndex = nil
            activeFeed = nil
        }
        try await feedManager.remove(id)
        installedFeeds = await feedManager.installedFeeds
        if graph == nil {
            if let next = installedFeeds.first {
                try await activate(feedID: next.id)
            } else {
                state = .needsFeed
            }
        }
    }

    /// Refreshes the active feed if it is older than `maximumAge`. Returns true
    /// when new data was installed.
    @discardableResult
    public func refreshActiveFeed(maximumAge: TimeInterval = 60 * 60 * 24 * 3) async throws -> Bool {
        guard let feedManager, let activeFeed else { return false }
        let changed = try await feedManager.refreshIfNeeded(
            activeFeed.id, maximumAge: maximumAge
        ) { progress in
            Task { @MainActor [weak self] in self?.installProgress = progress }
        }
        installProgress = nil
        if changed {
            try await activate(feedID: activeFeed.id)
        }
        return changed
    }

    private func buildAuxiliaryIndexes(for graph: TransitGraph, feed: InstalledFeed) {
        Task.detached(priority: .utility) { [weak self] in
            let index = StopSearchIndex(graph: graph)
            let lookup = RealtimeTripLookup(graph: graph)
            await MainActor.run { [weak self] in
                guard let self, self.graph === graph else { return }
                self.searchIndex = index
                self.realtimeLookup = lookup
                self.configureRealtime(for: feed, graph: graph, lookup: lookup)
            }
        }
    }

    // MARK: - Realtime

    private func configureRealtime(for feed: InstalledFeed, graph: TransitGraph, lookup: RealtimeTripLookup) {
        let source = feed.source
        guard source.realtimeTripUpdatesURL != nil || source.realtimeAlertsURL != nil else { return }
        realtimeFetcher = RealtimeFetcher(
            graph: graph,
            tripUpdatesURL: source.realtimeTripUpdatesURL,
            alertsURL: source.realtimeAlertsURL,
            headers: source.requestHeaders,
            lookup: lookup
        )
    }

    /// Begins polling the active feed's realtime endpoint. Called when a screen
    /// that shows live times appears, and stopped when it goes away — a bus app
    /// that polls in the background for no reason is a bus app people delete.
    public func startRealtimePolling(interval: TimeInterval = 30) {
        guard let fetcher = realtimeFetcher, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let index = try? await fetcher.refresh() {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.engine?.realtime = index
                        self.realtimeUpdatedAt = index.generatedAt
                        self.alerts = index.alerts
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopRealtimePolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Forces one realtime refresh, for pull-to-refresh.
    public func refreshRealtime() async {
        guard let fetcher = realtimeFetcher else { return }
        if let index = try? await fetcher.refresh() {
            engine?.realtime = index
            realtimeUpdatedAt = index.generatedAt
            alerts = index.alerts
        }
    }

    // MARK: - Queries

    public func plan(_ request: PlanRequest) async throws -> PlanResult {
        guard let engine else { throw TransitServiceError.noActiveFeed }
        return try await run { try engine.planner.plan(request, realtime: engine.realtime) }
    }

    public func departures(
        near point: GeoPoint,
        radiusMeters: Double = 500,
        limit: Int = 40,
        windowSeconds: Int = 3 * 3600,
        modes: Set<TransitMode>? = nil
    ) async -> [Departure] {
        guard let engine else { return [] }
        let instant = currentInstant()
        return (try? await run {
            let nearby = engine.graph.stops(near: point, radiusMeters: radiusMeters, limit: 60)
            guard !nearby.isEmpty else { return [] }
            return engine.board.departures(
                from: nearby.map(\.stop),
                after: instant,
                withinSeconds: windowSeconds,
                limit: limit,
                limitPerPattern: 3,
                modes: modes,
                realtime: engine.realtime
            )
        }) ?? []
    }

    public func departures(atStop stop: StopIndex, limit: Int = 60, windowSeconds: Int = 6 * 3600) async -> [Departure] {
        guard let engine else { return [] }
        let instant = currentInstant()
        return (try? await run {
            engine.board.departures(
                from: [stop],
                after: instant,
                withinSeconds: windowSeconds,
                limit: limit,
                limitPerPattern: 8,
                modes: nil,
                realtime: engine.realtime
            )
        }) ?? []
    }

    /// Every stop belonging to the same station as `stop`, so a departures screen
    /// can show all platforms of an interchange together.
    public func siblingStops(of stop: StopIndex) -> [StopIndex] {
        guard let graph else { return [stop] }
        let station = graph.stopStation(stop)
        guard station != stop || graph.stopIsStation(stop) else { return [stop] }
        var result: [StopIndex] = []
        for candidate in 0..<graph.stopCount where graph.stopStation(StopIndex(candidate)) == station {
            result.append(StopIndex(candidate))
        }
        return result.isEmpty ? [stop] : result
    }

    public func searchStops(_ query: String, near origin: GeoPoint? = nil, limit: Int = 25) -> [StopSearchIndex.Result] {
        searchIndex?.search(query, near: origin, limit: limit) ?? []
    }

    public func nearbyStops(to point: GeoPoint, radiusMeters: Double = 600, limit: Int = 30) -> [NearbyStop] {
        graph?.stops(near: point, radiusMeters: radiusMeters, limit: limit) ?? []
    }

    // MARK: - Plumbing

    /// Runs a synchronous engine call off the main actor.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func feedDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Feeds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Timetables are reproducible from the network, so keep them out of
        // iCloud backups; a 200 MB graph in a user's backup is pure waste.
        var mutable = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        return directory
    }
}
