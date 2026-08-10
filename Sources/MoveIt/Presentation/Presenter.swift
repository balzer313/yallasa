import Foundation
import SwiftUI
import MoveItKit

/// Turns engine values into view data. Holds the graph so views never have to.
///
/// This is the *only* type in the app target that touches `TransitGraph`. Every
/// name, colour and headsign a rider sees is read here and copied into a plain
/// struct, so a feed swap can never leave a half-rendered row reading indices out
/// of a graph that has been unmapped.
///
/// Methods return optionals wherever the graph may have gone away or an index may
/// be stale. Callers drop the nils; a departures board with one missing row is a
/// far better outcome than a crash in the middle of a commute.
@MainActor
public final class Presenter {
    private let service: TransitService

    public init(service: TransitService) {
        self.service = service
    }

    public var timeZone: TimeZone { service.timeZone }

    public var isReady: Bool { service.graph != nil }

    private var graph: TransitGraph? { service.graph }

    // MARK: - Badges

    public func badge(forRoute route: RouteIndex) -> LineBadgeData {
        guard let graph, isValid(route: route, in: graph) else {
            // Never nil: a badge is structural, and a row that lost its route is
            // still worth showing with its destination and time.
            return LineBadgeData(
                text: "—",
                backgroundHex: TransitMode.other.defaultColor,
                foregroundHex: 0xFFFFFF,
                mode: .other,
                accessibilityLabel: String(localized: "Unknown line")
            )
        }

        let mode = graph.routeMode(route)
        var text = graph.routeDisplayName(route)
        if text.isEmpty { text = graph.routeIdentifier(route) }

        return LineBadgeData(
            text: text,
            backgroundHex: graph.routeColor(route),
            foregroundHex: graph.routeTextColor(route),
            mode: mode,
            accessibilityLabel: Presenter.spokenLineName(mode: mode, text: text)
        )
    }

    /// "Bus 42" rather than "42". VoiceOver reading a bare number out of a list
    /// tells a blind rider nothing about what is about to pull up.
    public static func spokenLineName(mode: TransitMode, text: String) -> String {
        switch mode {
        case .bus, .trolleybus: return String(localized: "Bus \(text)")
        case .rail: return String(localized: "Train \(text)")
        case .subway: return String(localized: "Subway line \(text)")
        case .tram, .cableTram: return String(localized: "Tram \(text)")
        case .ferry: return String(localized: "Ferry \(text)")
        case .monorail: return String(localized: "Monorail \(text)")
        case .funicular: return String(localized: "Funicular \(text)")
        case .aerialLift: return String(localized: "Cable car \(text)")
        case .taxi: return String(localized: "Shared taxi \(text)")
        case .other: return String(localized: "Line \(text)")
        }
    }

    // MARK: - Departures

    public func departureItem(_ departure: Departure, walkMeters: Double?) -> DepartureItem? {
        guard let graph,
              graph.isValid(stop: departure.stop),
              isValid(pattern: departure.pattern, in: graph),
              isValid(trip: departure.trip, in: graph)
        else { return nil }

        return DepartureItem(
            id: departure.id,
            badge: badge(forRoute: departure.route),
            headsign: headsign(pattern: departure.pattern, trip: departure.trip, in: graph),
            stop: departure.stop,
            stopName: graph.stopName(departure.stop),
            stopCode: graph.stopCode(departure.stop),
            pattern: departure.pattern,
            trip: departure.trip,
            position: departure.position,
            departureSeconds: departure.actualDeparture,
            scheduledSeconds: departure.scheduledDeparture,
            queryDate: departure.queryDate,
            status: LiveStatus(delay: departure.delay, isCancelled: departure.isCancelled),
            walkMeters: walkMeters
        )
    }

    // MARK: - Stops

    public func stopItem(_ stop: StopIndex, distanceMeters: Double?) -> StopItem? {
        guard let graph, graph.isValid(stop: stop) else { return nil }

        return StopItem(
            id: stop,
            stop: stop,
            name: graph.stopName(stop),
            code: graph.stopCode(stop),
            coordinate: graph.stopCoordinate(stop),
            distanceMeters: distanceMeters,
            lines: lineBadges(atStop: stop, in: graph, limit: 8),
            accessibility: graph.stopAccessibility(stop)
        )
    }

    public func stopName(_ stop: StopIndex) -> String {
        guard let graph, graph.isValid(stop: stop) else { return String(localized: "Unknown stop") }
        let name = graph.stopName(stop)
        return name.isEmpty ? String(localized: "Unnamed stop") : name
    }

    // MARK: - Stable identifiers
    //
    // Favourites and saved places persist across feed rebuilds, and a rebuild
    // renumbers every index in the graph. Storing an index would silently point a
    // saved stop at a different bus stop after an update, which is worse than
    // losing the favourite — so anything durable is keyed by the GTFS string id,
    // and this is where views obtain it.

    public func stopIdentifier(_ stop: StopIndex) -> String? {
        guard let graph, graph.isValid(stop: stop) else { return nil }
        let identifier = graph.stopIdentifier(stop)
        return identifier.isEmpty ? nil : identifier
    }

    public func routeIdentifier(_ route: RouteIndex) -> String? {
        guard let graph, route >= 0, Int(route) < graph.routeCount else { return nil }
        let identifier = graph.routeIdentifier(route)
        return identifier.isEmpty ? nil : identifier
    }

    /// Resolves a stored GTFS stop id back to an index in the current graph.
    /// Returns nil when the stop no longer exists, which is how a stale favourite
    /// gets dropped rather than mis-resolved.
    public func stopIndex(forIdentifier identifier: String) -> StopIndex? {
        guard let graph else { return nil }
        for raw in 0..<graph.stopCount where graph.stopIdentifier(StopIndex(raw)) == identifier {
            return StopIndex(raw)
        }
        return nil
    }

    // MARK: - Journeys

    public func journeyItem(_ journey: Journey) -> JourneyItem {
        var legs: [JourneyLegItem] = []
        legs.reserveCapacity(journey.legs.count)
        var badges: [LineBadgeData] = []

        for (offset, leg) in journey.legs.enumerated() {
            switch leg {
            case .walk(let walk):
                legs.append(
                    JourneyLegItem(
                        id: "\(journey.id)#\(offset)",
                        kind: .walk,
                        badge: nil,
                        headsign: "",
                        fromName: walk.origin.name,
                        toName: walk.destination.name,
                        fromStop: walk.origin.stop,
                        toStop: walk.destination.stop,
                        departureSeconds: walk.departure,
                        arrivalSeconds: walk.arrival,
                        status: .scheduled,
                        distanceMeters: walk.distanceMeters,
                        intermediateStopCount: 0,
                        intermediateStopNames: []
                    )
                )

            case .ride(let ride):
                let rideBadge = badge(forRoute: ride.route)
                badges.append(rideBadge)
                legs.append(
                    JourneyLegItem(
                        id: "\(journey.id)#\(offset)",
                        kind: .ride,
                        badge: rideBadge,
                        headsign: graph.map { headsign(pattern: ride.pattern, trip: ride.trip, in: $0) } ?? "",
                        fromName: stopName(ride.boardStop),
                        toName: stopName(ride.alightStop),
                        fromStop: ride.boardStop,
                        toStop: ride.alightStop,
                        departureSeconds: ride.actualDeparture,
                        arrivalSeconds: ride.actualArrival,
                        status: LiveStatus(delay: ride.departureDelay, isCancelled: false),
                        distanceMeters: 0,
                        intermediateStopCount: max(0, ride.alightPosition - ride.boardPosition - 1),
                        // Capped: a detail screen shows a summary of the ride, and
                        // a 60-stop commuter line would otherwise build 60 strings
                        // per result row.
                        intermediateStopNames: intermediateStopNames(
                            pattern: ride.pattern,
                            from: ride.boardPosition,
                            to: ride.alightPosition,
                            limit: 24
                        )
                    )
                )
            }
        }

        return JourneyItem(
            id: journey.id,
            journey: journey,
            legs: legs,
            departureSeconds: journey.departure,
            arrivalSeconds: journey.arrival,
            baseDate: journey.baseDate,
            durationSeconds: journey.durationSeconds,
            transferCount: journey.transferCount,
            walkMeters: journey.walkingMeters,
            badges: badges,
            isWalkOnly: journey.isWalkOnly,
            hasRealtime: journey.usesRealtime
        )
    }

    // MARK: - Patterns

    public func patternItem(_ pattern: PatternIndex) -> PatternItem? {
        guard let graph, isValid(pattern: pattern, in: graph) else { return nil }

        let route = graph.patternRoute(pattern)
        var sign = graph.patternHeadsign(pattern)
        if sign.isEmpty {
            let count = graph.patternStopCount(pattern)
            if count > 0 { sign = stopName(graph.patternStop(pattern, at: count - 1)) }
        }

        return PatternItem(
            id: pattern,
            pattern: pattern,
            route: route,
            badge: badge(forRoute: route),
            headsign: sign,
            stopCount: graph.patternStopCount(pattern),
            direction: graph.patternDirection(pattern)
        )
    }

    /// Names of the stops strictly between two positions on a pattern.
    public func intermediateStopNames(pattern: PatternIndex, from: Int, to: Int, limit: Int) -> [String] {
        guard let graph, isValid(pattern: pattern, in: graph), limit > 0 else { return [] }

        let stopCount = graph.patternStopCount(pattern)
        let lower = max(0, from + 1)
        let upper = min(stopCount, to)
        guard lower < upper else { return [] }

        var names: [String] = []
        names.reserveCapacity(min(limit, upper - lower))
        for position in lower..<upper {
            if names.count >= limit { break }
            let stop = graph.patternStop(pattern, at: position)
            guard graph.isValid(stop: stop) else { continue }
            names.append(graph.stopName(stop))
        }
        return names
    }

    // MARK: - Private

    private func isValid(route: RouteIndex, in graph: TransitGraph) -> Bool {
        route >= 0 && Int(route) < graph.routeCount
    }

    private func isValid(pattern: PatternIndex, in graph: TransitGraph) -> Bool {
        pattern >= 0 && Int(pattern) < graph.patternCount
    }

    private func isValid(trip: TripIndex, in graph: TransitGraph) -> Bool {
        trip >= 0 && Int(trip) < graph.tripCount
    }

    /// Trip headsign, then pattern headsign, then the pattern's last stop. Feeds
    /// populate exactly one of the three with any consistency, and "towards
    /// nowhere" is the least useful thing a departures board can say.
    private func headsign(pattern: PatternIndex, trip: TripIndex, in graph: TransitGraph) -> String {
        let tripSign = graph.tripHeadsign(trip)
        if !tripSign.isEmpty { return tripSign }

        let patternSign = graph.patternHeadsign(pattern)
        if !patternSign.isEmpty { return patternSign }

        let stopCount = graph.patternStopCount(pattern)
        guard stopCount > 0 else { return "" }
        let terminus = graph.patternStop(pattern, at: stopCount - 1)
        guard graph.isValid(stop: terminus) else { return "" }
        return graph.stopName(terminus)
    }

    /// The lines a rider would say serve this stop.
    ///
    /// Deduped on the rendered text rather than on `RouteIndex`, because plenty of
    /// feeds publish one route record per direction — showing "5, 5, 5, 5" on a
    /// stop card is noise, not information.
    private func lineBadges(atStop stop: StopIndex, in graph: TransitGraph, limit: Int) -> [LineBadgeData] {
        var seen = Set<String>()
        var badges: [LineBadgeData] = []

        for slot in graph.patternSlots(atStop: stop) {
            guard slot >= 0, slot < graph.stopPatternReferences.count else { continue }
            let pattern = graph.stopPatternReferences[slot]
            guard isValid(pattern: pattern, in: graph) else { continue }
            let route = graph.patternRoute(pattern)
            guard isValid(route: route, in: graph) else { continue }

            let item = badge(forRoute: route)
            guard seen.insert("\(item.mode.rawValue)|\(item.text)").inserted else { continue }
            badges.append(item)
        }

        badges.sort { lhs, rhs in
            if lhs.mode.displayPriority != rhs.mode.displayPriority {
                return lhs.mode.displayPriority < rhs.mode.displayPriority
            }
            // Standard compare so "10" sorts after "9" rather than before it.
            return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        }

        if badges.count > limit { badges.removeSubrange(limit...) }
        return badges
    }
}

// MARK: - Environment

private struct PresenterEnvironmentKey: EnvironmentKey {
    /// Optional rather than a lazily built default: constructing a `Presenter`
    /// requires the main actor, and an `EnvironmentKey`'s default is evaluated in
    /// a nonisolated static context.
    static let defaultValue: Presenter? = nil
}

public extension EnvironmentValues {
    /// The shared presenter, injected once by `RootView`.
    ///
    /// Screens owned by other agents are constructed inside the shell's
    /// `navigationDestination` blocks, so the environment is the one channel that
    /// does not require the shell to know their initialiser signatures.
    var presenter: Presenter? {
        get { self[PresenterEnvironmentKey.self] }
        set { self[PresenterEnvironmentKey.self] = newValue }
    }
}
