import Foundation
import Combine
import MoveItKit

/// The Nearby board's state machine.
///
/// Everything expensive already happens off the main actor inside
/// `TransitService`; this type's job is to decide *when* to ask, to convert the
/// answer through `Presenter`, and to be honest about which of the four states
/// the screen is in.
@MainActor
final class NearbyViewModel: ObservableObject {

    /// A stop and the departures leaving it, which is how a rider reads a board:
    /// "what leaves from the corner I am standing on".
    struct StopGroup: Identifiable, Hashable {
        var stop: StopItem
        var departures: [DepartureItem]

        var id: StopIndex { stop.id }
    }

    enum Phase: Equatable {
        case loading
        case content
        case empty
        /// No location *and* no feed centre to fall back on.
        case locationUnavailable
        case failed(String)
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var groups: [StopGroup] = []
    @Published private(set) var availableModes: [TransitMode] = []
    @Published var selectedModes: Set<TransitMode> = []
    /// The day frame every countdown on screen is measured against.
    @Published private(set) var queryDate: ServiceDate
    /// True when the board is centred on the feed's own centre rather than on the
    /// rider. Drives the "showing the city centre" notice.
    @Published private(set) var usingFallbackLocation = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var searchRadiusMeters: Double = NearbyViewModel.baseRadiusMeters

    // MARK: - Tuning

    private static let baseRadiusMeters: Double = 600
    /// Escalation ladder for sparse coverage — a suburb where the nearest stop is
    /// 1.5 km away should still show something rather than claim there is nothing.
    private static let radiusLadder: [Double] = [600, 1_200, 2_500]
    private static let departureLimit = 150
    private static let windowSeconds = 3 * 3_600
    /// Rows per stop before the card offers "see all". Four fits on screen next to
    /// three other stops, which is the shape of a useful board.
    static let rowsPerStop = 4

    // MARK: - Dependencies

    private let service: TransitService
    private let location: LocationProvider
    private let presenter: Presenter

    private var cancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var lastOrigin: GeoPoint?
    private var hasLoadedOnce = false

    init(service: TransitService, location: LocationProvider, presenter: Presenter) {
        self.service = service
        self.location = location
        self.presenter = presenter
        self.queryDate = ServiceDate(date: Date(), in: service.timeZone)

        // A realtime snapshot changes every countdown on screen, so re-derive the
        // board rather than letting the timer tick against stale delays.
        service.$realtimeUpdatedAt
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.load(silently: true) }
            }
            .store(in: &cancellables)

        // A newly activated feed invalidates every index we are holding.
        service.$state
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if state.isReady { await self.load() }
                }
            }
            .store(in: &cancellables)

        location.$coordinate
            .compactMap { $0 }
            .sink { [weak self] point in
                Task { @MainActor [weak self] in self?.locationDidUpdate(to: point) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    /// Filtering happens here, not in a reload: the rider tapping "Bus" is asking
    /// to hide rows, not to wait for the engine again.
    var filteredGroups: [StopGroup] {
        guard !selectedModes.isEmpty else { return groups }
        return groups.compactMap { group in
            let kept = group.departures.filter { selectedModes.contains($0.badge.mode) }
            guard !kept.isEmpty else { return nil }
            return StopGroup(stop: group.stop, departures: kept)
        }
    }

    var isFiltering: Bool { !selectedModes.isEmpty }

    var showsLocationDeniedNotice: Bool { location.isDenied }

    var showsPermissionPrompt: Bool { location.authorization == .notDetermined }

    // MARK: - Lifecycle

    func onAppear() async {
        location.start()
        service.startRealtimePolling(interval: 30)
        if !hasLoadedOnce { await load() }
    }

    func onDisappear() {
        service.stopRealtimePolling()
        location.stop()
        loadTask?.cancel()
    }

    func requestLocationPermission() {
        location.requestPermission()
    }

    // MARK: - Loading

    /// Pull to refresh: force a realtime fetch first so the board that comes back
    /// is genuinely newer, then recompute.
    func refresh() async {
        isRefreshing = true
        await service.refreshRealtime()
        await load(silently: true)
        isRefreshing = false
    }

    func retry() async {
        await load()
    }

    func toggleMode(_ mode: TransitMode) {
        if selectedModes.contains(mode) {
            selectedModes.remove(mode)
        } else {
            selectedModes.insert(mode)
        }
    }

    func clearModeFilter() {
        selectedModes.removeAll()
    }

    /// - Parameter silently: keep the current content on screen while reloading.
    ///   A realtime tick must never flash the skeleton back over a board the
    ///   rider is reading.
    func load(silently: Bool = false) async {
        loadTask?.cancel()
        // Unwrapped inside rather than `await self?.…`, whose result is `()?` and
        // therefore a `Task<()?, Never>` that will not fit the stored property.
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(silently: silently)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(silently: Bool) async {
        guard service.state.isReady, presenter.isReady else {
            // The feed gate owns this case; the board just waits.
            if !silently { phase = .loading }
            return
        }

        if !silently, groups.isEmpty { phase = .loading }

        let fallback = service.graph?.metadata.bounds.center
        guard let origin = location.bestGuessCoordinate(fallback: fallback), origin.isValid else {
            phase = .locationUnavailable
            return
        }

        usingFallbackLocation = !(location.coordinate?.isValid ?? false)
        lastOrigin = origin

        // Grow the radius only until something is found. Starting wide would pull
        // in a dozen stops the rider will never walk to and bury the one across
        // the street.
        var nearby: [NearbyStop] = []
        var radius = NearbyViewModel.baseRadiusMeters
        for candidate in NearbyViewModel.radiusLadder {
            radius = candidate
            nearby = service.nearbyStops(to: origin, radiusMeters: candidate, limit: 40)
            if !nearby.isEmpty { break }
        }
        searchRadiusMeters = radius

        guard !nearby.isEmpty else {
            groups = []
            availableModes = []
            phase = .empty
            return
        }

        let departures = await service.departures(
            near: origin,
            radiusMeters: radius,
            limit: NearbyViewModel.departureLimit,
            windowSeconds: NearbyViewModel.windowSeconds,
            modes: nil
        )

        guard !Task.isCancelled else { return }

        var distanceByStop: [StopIndex: Double] = [:]
        distanceByStop.reserveCapacity(nearby.count)
        for entry in nearby { distanceByStop[entry.stop] = entry.distanceMeters }

        var itemsByStop: [StopIndex: [DepartureItem]] = [:]
        var modes: Set<TransitMode> = []
        for departure in departures {
            guard let item = presenter.departureItem(
                departure,
                walkMeters: distanceByStop[departure.stop]
            ) else { continue }
            modes.insert(item.badge.mode)
            itemsByStop[departure.stop, default: []].append(item)
        }

        // Nearest first: the board is ordered by how long it takes to get to the
        // stop, not by how soon something leaves it.
        var built: [StopGroup] = []
        built.reserveCapacity(nearby.count)
        for entry in nearby {
            guard let items = itemsByStop[entry.stop], !items.isEmpty else { continue }
            guard let stopItem = presenter.stopItem(entry.stop, distanceMeters: entry.distanceMeters) else { continue }
            built.append(
                StopGroup(
                    stop: stopItem,
                    departures: items.sorted { $0.departureSeconds < $1.departureSeconds }
                )
            )
        }

        groups = built
        availableModes = modes.sorted {
            $0.displayPriority == $1.displayPriority
                ? $0.rawValue < $1.rawValue
                : $0.displayPriority < $1.displayPriority
        }
        // Drop filter selections that no longer match anything, otherwise a mode
        // chosen at one stop silently empties the board at the next.
        selectedModes.formIntersection(modes)
        queryDate = departures.first?.queryDate ?? ServiceDate(date: Date(), in: service.timeZone)
        phase = built.isEmpty ? .empty : .content
        hasLoadedOnce = true
    }

    // MARK: - Location

    private func locationDidUpdate(to point: GeoPoint) {
        guard let previous = lastOrigin else {
            Task { @MainActor [weak self] in await self?.load(silently: true) }
            return
        }
        // 75 m is a block. Reloading on every 20 m fix would rebuild the board
        // while the rider is still walking towards the stop it is describing.
        guard previous.approximateDistance(to: point) > 75 else { return }
        Task { @MainActor [weak self] in await self?.load(silently: true) }
    }
}
