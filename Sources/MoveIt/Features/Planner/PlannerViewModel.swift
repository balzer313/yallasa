import Combine
import Foundation
import MoveItKit
import SwiftUI

/// Drives the from/to screen.
///
/// Owns exactly one in-flight plan. Every input change cancels the previous
/// search and starts a new one, because a rider who edits the destination twice
/// must never see the first answer land on top of the second.
@MainActor
final class PlannerViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case results([JourneyItem])
        case empty(PlannerEmptyReason)
        case failed(String)

        var results: [JourneyItem] {
            if case .results(let items) = self { return items }
            return []
        }
    }

    // MARK: Inputs

    @Published var origin: PlannerEndpoint = .currentLocation
    @Published var destination: PlannerEndpoint?
    @Published var timeMode: PlannerTimeMode = .leaveNow
    /// Only meaningful when `timeMode.usesExplicitTime`.
    @Published var selectedDate: Date = Date()

    // MARK: Outputs

    @Published private(set) var phase: Phase = .idle
    /// A background refresh that must not blank the list out.
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingFeed = false
    @Published private(set) var optionsState = PlannerOptionsState()

    private let service: TransitService
    private let presenter: Presenter
    private let location: LocationProvider?

    private var planTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Bumped on every request so a late continuation can tell whether it is
    /// still the answer anybody is waiting for.
    private var generation = 0
    /// The list is under the rider's thumb. Re-ordering rows now would move the
    /// bus they are reaching for out from under the tap.
    private var isScrolling = false
    private var scrollSettleTask: Task<Void, Never>?

    init(
        service: TransitService = .shared,
        presenter: Presenter? = nil,
        location: LocationProvider? = nil
    ) {
        self.service = service
        self.presenter = presenter ?? Presenter(service: service)
        self.location = location
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard cancellables.isEmpty else { return }

        // Live times are the whole point of the results list, so the screen asks
        // for realtime while it is on screen. It deliberately does not stop
        // polling on disappear: Nearby may still be relying on it, and there is
        // no shared refcount to consult.
        service.startRealtimePolling(interval: 30)

        // The hop through a main-actor Task is deliberate: Combine's sink closure
        // carries no actor isolation of its own, so touching the view model from
        // inside it has to be spelled out.
        service.$realtimeUpdatedAt
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.realtimeDidUpdate() }
            }
            .store(in: &cancellables)

        // A feed arriving after the screen was built should fill it in rather
        // than leave the rider staring at "no timetable yet".
        service.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state.isReady else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if case .empty(.noFeed) = self.phase { self.plan() }
                }
            }
            .store(in: &cancellables)

        if case .idle = phase { plan() }
    }

    func onDisappear() {
        planTask?.cancel()
        realtimeTask?.cancel()
        scrollSettleTask?.cancel()
        planTask = nil
        realtimeTask = nil
        scrollSettleTask = nil
    }

    var timeZone: TimeZone { service.timeZone }

    var showsTimeZoneHint: Bool { Format.needsTimeZoneLabel(timeZone) }

    var timeZoneHint: String {
        String(localized: "Times in \(timeZone.localizedName(for: .shortGeneric, locale: .current) ?? timeZone.identifier)")
    }

    /// What the time control reads out, already in the feed's zone.
    var timeSummary: String {
        switch timeMode {
        case .leaveNow:
            return String(localized: "Leaving now")
        case .leaveAt:
            return String(localized: "Leaving \(Format.clockWithDay(selectedDate, in: timeZone))")
        case .arriveBy:
            return String(localized: "Arriving by \(Format.clockWithDay(selectedDate, in: timeZone))")
        }
    }

    // MARK: - Endpoint editing

    func setEndpoint(_ endpoint: PlannerEndpoint, for field: PlannerField) {
        switch field {
        case .origin: origin = endpoint
        case .destination: destination = endpoint
        }
        plan()
    }

    func swapEndpoints() {
        // Swapping into an empty destination would silently wipe the origin, so
        // the swap only happens once both ends exist.
        guard let destination else { return }
        let previousOrigin = origin
        self.origin = destination
        self.destination = previousOrigin
        plan()
    }

    var canSwap: Bool { destination != nil }

    func setTimeMode(_ mode: PlannerTimeMode) {
        guard mode != timeMode else { return }
        if mode.usesExplicitTime, timeMode == .leaveNow {
            // Seed the picker with "about now" rather than whatever stale value
            // it last held.
            selectedDate = Date()
        }
        timeMode = mode
        plan()
    }

    func setSelectedDate(_ date: Date) {
        guard date != selectedDate else { return }
        selectedDate = date
        plan()
    }

    // MARK: - Options

    func apply(_ state: PlannerOptionsState) {
        guard state != optionsState else { return }
        optionsState = state
        // Only re-run if there is something to re-run; changing options before
        // picking a destination should not flash a spinner.
        if destination != nil { plan() }
    }

    private var planOptions: PlanOptions {
        var options = PlanOptions()
        optionsState.apply(to: &options)
        return options
    }

    // MARK: - Scrolling

    func scrollingBegan() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        isScrolling = true
    }

    /// The finger left the glass. Momentum can carry the list for a while after
    /// that, and iOS 17 gives SwiftUI no scroll-phase callback, so "at rest" is
    /// approximated as "no drag for a beat".
    func scrollingEnded() {
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.isScrolling = false
        }
    }

    // MARK: - Realtime

    private func realtimeDidUpdate() {
        // Only refresh a list that is actually showing results; a realtime tick
        // is not a reason to start a search the rider never asked for.
        guard case .results = phase else { return }
        realtimeTask?.cancel()
        realtimeTask = Task { [weak self] in
            // Debounce: feeds routinely land two snapshots seconds apart.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }

            var waits = 0
            while self.isScrolling, waits < 40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                waits += 1
            }
            guard !Task.isCancelled else { return }
            self.plan(quietly: true)
        }
    }

    // MARK: - Planning

    var canPlan: Bool { destination != nil }

    func plan(quietly: Bool = false) {
        #if DEBUG
        // A pinned preview must not be overwritten by the "no feed installed"
        // answer the real service would give.
        if isPreviewPinned { return }
        #endif
        planTask?.cancel()

        guard service.state.isReady else {
            phase = .empty(.noFeed)
            return
        }
        guard let destination else {
            phase = .empty(.notEnoughInput)
            return
        }
        guard let originEndpoint = resolve(origin) else {
            phase = .empty(.needsLocation)
            return
        }
        guard let destinationEndpoint = resolve(destination) else {
            phase = .empty(.notEnoughInput)
            return
        }

        let anchorDate = timeMode.usesExplicitTime ? selectedDate : Date()
        let instant = ServiceInstant(date: anchorDate, in: timeZone)
        let anchor: PlanTimeAnchor = timeMode == .arriveBy
            ? .arriveBy(instant)
            : .departAfter(instant)

        let request = PlanRequest(
            origin: originEndpoint,
            destination: destinationEndpoint,
            anchor: anchor,
            options: planOptions
        )

        generation += 1
        let token = generation

        if quietly {
            isRefreshing = true
        } else {
            phase = .loading
        }

        planTask = Task { [weak self] in
            guard let self else { return }
            defer { if quietly { self.isRefreshing = false } }
            do {
                let result = try await self.service.plan(request)
                guard !Task.isCancelled, token == self.generation else { return }
                let items = result.journeys.map(self.presenter.journeyItem)
                self.phase = items.isEmpty ? .empty(.noResults) : .results(items)
            } catch is CancellationError {
                return
            } catch let error as PlanError {
                guard !Task.isCancelled, token == self.generation else { return }
                if case .cancelled = error { return }
                // A quiet refresh that fails should leave the last good answer on
                // screen rather than replace it with an error the rider did not
                // provoke.
                if quietly, case .results = self.phase { return }
                self.phase = .empty(PlannerEmptyReason(planError: error))
            } catch {
                guard !Task.isCancelled, token == self.generation else { return }
                if quietly, case .results = self.phase { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Pull-to-refresh. Awaits the search so the control animates for the real
    /// duration instead of snapping back immediately.
    func refresh() async {
        plan(quietly: phase.results.isEmpty == false)
        await planTask?.value
    }

    /// Offered when the timetable does not cover the requested date — the only
    /// fix for that is newer data.
    func refreshFeed() async {
        guard !isRefreshingFeed else { return }
        isRefreshingFeed = true
        defer { isRefreshingFeed = false }
        do {
            // maximumAge 0 forces the check; the manager still no-ops when the
            // publisher has nothing newer.
            _ = try await service.refreshActiveFeed(maximumAge: 0)
            plan()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Resolution

    private func resolve(_ endpoint: PlannerEndpoint) -> PlanEndpoint? {
        if let resolved = endpoint.planEndpoint { return resolved }
        switch endpoint.kind {
        case .currentLocation:
            guard let point = currentCoordinate() else { return nil }
            return .coordinate(point)
        case .stop(let stop):
            return .stop(stop)
        case .coordinate:
            guard let coordinate = endpoint.coordinate else { return nil }
            return .coordinate(coordinate)
        }
    }

    /// Where the rider is, or the best stand-in. The feed's centre keeps the
    /// planner usable with location denied, which is a real and common state.
    func currentCoordinate() -> GeoPoint? {
        let fallback = service.activeFeed?.source.bounds?.center
        if let location { return location.bestGuessCoordinate(fallback: fallback) }
        return fallback
    }

    #if DEBUG
    private var isPreviewPinned = false

    /// Previews only: drop straight into a state without a graph.
    func previewSet(phase: Phase, destination: PlannerEndpoint? = nil) {
        isPreviewPinned = true
        self.phase = phase
        if let destination { self.destination = destination }
    }
    #endif
}
