import Foundation
import Combine
import MoveItKit

// MARK: - View data

/// One stop along a pattern.
struct PatternStopItem: Identifiable, Hashable, Sendable {
    var position: Int
    var stop: StopIndex
    var name: String
    var code: String
    var accessibility: AccessibilityFlag
    /// Cumulative straight-line metres from the first stop.
    var distanceMeters: Int32

    var id: Int { position }
}

/// A selectable variant of a line: usually two directions, sometimes a handful
/// of short-workings and school-day extras on top.
struct PatternOption: Identifiable, Hashable, Sendable {
    var pattern: PatternIndex
    var headsign: String
    var direction: UInt8
    var stopCount: Int
    var tripCount: Int
    var firstStopName: String
    var lastStopName: String

    var id: PatternIndex { pattern }

    var subtitle: String {
        String(localized: "\(Format.stopCount(stopCount)) · \(tripCount) trips")
    }
}

/// Everything one direction of a line needs to draw itself.
struct PatternDetailData: Hashable, Sendable {
    var pattern: PatternIndex
    var route: RouteIndex
    var routeIdentifier: String
    var badge: LineBadgeData
    var mode: TransitMode
    var routeLongName: String
    var routeDescription: String
    var agencyName: String
    var headsign: String
    var direction: UInt8
    var accessibility: AccessibilityFlag
    var tripCount: Int
    var stops: [PatternStopItem]
    /// Every pattern of the same route, in a stable order.
    var options: [PatternOption]

    var directions: [UInt8] {
        Array(Set(options.map(\.direction))).sorted()
    }

    /// Variants running in the currently shown direction.
    var optionsInSelectedDirection: [PatternOption] {
        options.filter { $0.direction == direction }
    }

    var patternsInSelectedDirection: Set<PatternIndex> {
        Set(optionsInSelectedDirection.map(\.pattern))
    }

    var terminus: String {
        headsign.isEmpty ? (stops.last?.name ?? "") : headsign
    }

    var origin: String { stops.first?.name ?? "" }
}

/// A single timetable departure, already formatted for display.
struct TimetableEntry: Identifiable, Hashable {
    var id: String
    var seconds: ServiceSeconds
    /// "07" — the minutes cell of the hour grid.
    var minuteText: String
    /// "14:07" — used for VoiceOver and for the compact list.
    var clockText: String
    var isAccessible: Bool
}

/// One hour of the timetable grid.
struct TimetableHour: Identifiable, Hashable {
    /// Raw GTFS hour, which may be 24 or more for after-midnight service.
    var id: Int
    var label: String
    var isAfterMidnight: Bool
    var entries: [TimetableEntry]
}

enum LoadPhase: Equatable {
    case loading
    case empty
    case error(String)
    case content
}

// MARK: - View model

/// Drives pattern detail: the stop list, the next departures from one stop, and
/// the full timetable for a chosen day.
///
/// The two expensive jobs — finding a route's patterns among all of them, and
/// expanding every trip of a pattern for a service date — are both linear in
/// feed size, so both run in detached tasks and land as published state.
@MainActor
final class PatternDetailViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case error(String)
        case content
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var detail: PatternDetailData?

    @Published private(set) var selectedPosition: Int = 0
    @Published private(set) var departures: [DepartureItem] = []
    @Published private(set) var departuresPhase: LoadPhase = .loading

    @Published private(set) var timetable: [TimetableHour] = []
    @Published private(set) var timetablePhase: LoadPhase = .loading
    @Published private(set) var timetableDate: Date = Date()
    @Published private(set) var timetableTotal: Int = 0

    @Published private(set) var timeZone: TimeZone = .current
    /// Days the installed feed can actually answer for, which is what the date
    /// picker must be clamped to.
    @Published private(set) var coverage: ClosedRange<Date>?

    private weak var service: TransitService?
    private var presenter: Presenter?
    private var buildTask: Task<Void, Never>?
    private var departuresTask: Task<Void, Never>?
    private var timetableTask: Task<Void, Never>?
    private var requestedPosition: Int?

    deinit {
        buildTask?.cancel()
        departuresTask?.cancel()
        timetableTask?.cancel()
    }

    /// "Now" in the same day frame the departures were computed in, so a
    /// countdown subtracts two comparable numbers.
    func seconds(at date: Date) -> ServiceSeconds {
        ServiceInstant(date: date, in: timeZone).seconds
    }

    var nowSeconds: ServiceSeconds { seconds(at: Date()) }

    // MARK: Loading

    func start(route: RouteIndex?, pattern: PatternIndex?, position: Int?, service: TransitService) {
        self.service = service
        if presenter == nil { presenter = Presenter(service: service) }
        self.requestedPosition = position
        self.timeZone = service.timeZone
        self.coverage = PatternDetailViewModel.coverageRange(for: service)

        guard let graph = service.graph else {
            switch service.state {
            case .failed(let message): phase = .error(message)
            default: phase = .loading
            }
            return
        }

        buildTask?.cancel()
        phase = .loading
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                PatternDetailData.build(route: route, pattern: pattern, graph: graph)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard let built else {
                self.phase = .error(String(localized: "This line is not in the installed timetable."))
                return
            }
            self.apply(built, resetPosition: true)
            self.phase = .content
        }
    }

    /// Switches to another variant or direction of the same line.
    func select(pattern: PatternIndex) {
        guard let service, let graph = service.graph, detail?.pattern != pattern else { return }
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                PatternDetailData.build(route: nil, pattern: pattern, graph: graph)
            }.value
            guard !Task.isCancelled, let self, let built else { return }
            self.apply(built, resetPosition: true)
        }
    }

    /// Switches direction, keeping the busiest variant in the new direction.
    func select(direction: UInt8) {
        guard let detail else { return }
        let candidates = detail.options.filter { $0.direction == direction }
        guard let best = candidates.max(by: { ($0.tripCount, $0.stopCount) < ($1.tripCount, $1.stopCount) }) else { return }
        select(pattern: best.pattern)
    }

    func select(position: Int) {
        guard let detail, position >= 0, position < detail.stops.count, position != selectedPosition else { return }
        selectedPosition = position
        reloadDepartures()
        reloadTimetable()
    }

    func setTimetableDate(_ date: Date) {
        guard !Calendar.current.isDate(date, inSameDayAs: timetableDate) else { return }
        timetableDate = date
        reloadTimetable()
    }

    private func apply(_ built: PatternDetailData, resetPosition: Bool) {
        detail = built
        if resetPosition {
            // The caller may have arrived from a departure row, in which case it
            // knows which stop the rider is standing at.
            if let requested = requestedPosition, requested >= 0, requested < built.stops.count {
                selectedPosition = requested
            } else {
                selectedPosition = 0
            }
            requestedPosition = nil
        }
        if selectedPosition >= built.stops.count { selectedPosition = 0 }
        reloadDepartures()
        reloadTimetable()
    }

    // MARK: Departures

    func reloadDepartures() {
        guard let service, let detail, selectedPosition < detail.stops.count else {
            departures = []
            departuresPhase = .empty
            return
        }
        let stop = detail.stops[selectedPosition].stop
        let wanted = detail.patternsInSelectedDirection

        departuresTask?.cancel()
        departuresPhase = departures.isEmpty ? .loading : departuresPhase
        departuresTask = Task { [weak self] in
            // A busy interchange returns departures for every line that calls
            // there, so ask for a generous slice and filter down to this line.
            let raw = await service.departures(atStop: stop, limit: 150)
            guard !Task.isCancelled, let self, let presenter = self.presenter else { return }
            let items = raw
                .filter { wanted.contains($0.pattern) }
                .compactMap { presenter.departureItem($0, walkMeters: nil) }
            self.departures = Array(items.prefix(12))
            self.departuresPhase = items.isEmpty ? .empty : .content
        }
    }

    // MARK: Timetable

    func reloadTimetable() {
        guard let service, let graph = service.graph, let detail, selectedPosition < detail.stops.count else {
            timetable = []
            timetablePhase = .empty
            return
        }
        let pattern = detail.pattern
        let position = selectedPosition
        let zone = service.timeZone
        let date = ServiceDate(date: timetableDate, in: zone)

        timetableTask?.cancel()
        timetablePhase = .loading
        timetableTask = Task { [weak self] in
            let slots = await Task.detached(priority: .userInitiated) {
                PatternDetailData.timetableSlots(pattern: pattern, position: position, date: date, graph: graph)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.timetableTotal = slots.count
            self.timetable = PatternDetailViewModel.group(slots, on: date, in: zone)
            self.timetablePhase = slots.isEmpty ? .empty : .content
        }
    }

    /// Formatting happens here, on the main actor, because `Format`'s clock
    /// formatter cache is not thread-safe. The raw expansion — the part that is
    /// linear in trip count — already happened off it.
    private static func group(_ slots: [TimetableSlot], on date: ServiceDate, in zone: TimeZone) -> [TimetableHour] {
        guard !slots.isEmpty else { return [] }
        var buckets: [Int: [TimetableEntry]] = [:]
        for slot in slots {
            let hour = Int(slot.seconds) / 3600
            let minute = (Int(slot.seconds) % 3600) / 60
            let instant = ServiceInstant(date: date, seconds: slot.seconds)
            buckets[hour, default: []].append(
                TimetableEntry(
                    id: "\(slot.trip)-\(slot.seconds)",
                    seconds: slot.seconds,
                    minuteText: String(format: "%02d", minute),
                    clockText: Format.clock(instant, in: zone),
                    isAccessible: slot.accessibility == .accessible
                )
            )
        }
        return buckets.keys.sorted().map { hour in
            TimetableHour(
                id: hour,
                label: String(format: "%02d", hour % 24),
                isAfterMidnight: hour >= 24,
                entries: (buckets[hour] ?? []).sorted { $0.seconds < $1.seconds }
            )
        }
    }

    private static func coverageRange(for service: TransitService) -> ClosedRange<Date>? {
        guard let metadata = service.activeFeed?.metadata ?? service.graph?.metadata else { return nil }
        let zone = service.timeZone
        guard metadata.calendarDayCount > 0,
              let end = metadata.calendarEnd,
              let startDate = metadata.calendarStart.startOfDay(in: zone),
              let endDate = end.startOfDay(in: zone),
              startDate <= endDate
        else { return nil }
        return startDate...endDate
    }
}
