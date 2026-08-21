import Foundation
import YallaSaKit

/// One expanded timetable departure, before formatting.
struct TimetableSlot: Hashable, Sendable {
    var trip: TripIndex
    var seconds: ServiceSeconds
    var accessibility: AccessibilityFlag
}

extension PatternDetailData {
    /// Builds one direction of a line.
    ///
    /// Finding the variants of a route means walking the whole pattern column —
    /// the graph indexes patterns by stop, not by route, because that is what
    /// RAPTOR needs. Tens of thousands of `Int32` reads is nothing off the main
    /// actor and a visible hitch on it, so this is `nonisolated` and always
    /// called from a detached task.
    ///
    /// Pass `pattern` to show a specific variant, or only `route` to let it pick
    /// the busiest one.
    nonisolated static func build(
        route requestedRoute: RouteIndex?,
        pattern requestedPattern: PatternIndex?,
        graph: TransitGraph
    ) -> PatternDetailData? {
        let patternCount = graph.patternCount
        guard patternCount > 0 else { return nil }

        func isValidPattern(_ pattern: PatternIndex) -> Bool {
            pattern >= 0 && Int(pattern) < patternCount
        }

        // Resolve which route we are describing.
        let route: RouteIndex
        if let requestedPattern, isValidPattern(requestedPattern) {
            route = graph.patternRoute(requestedPattern)
        } else if let requestedRoute {
            route = requestedRoute
        } else {
            return nil
        }
        guard route >= 0, Int(route) < graph.routeCount else { return nil }

        var options: [PatternOption] = []
        for raw in 0..<patternCount {
            let pattern = PatternIndex(raw)
            guard graph.patternRoute(pattern) == route else { continue }
            let stopCount = graph.patternStopCount(pattern)
            guard stopCount > 1 else { continue }
            options.append(
                PatternOption(
                    pattern: pattern,
                    headsign: graph.patternHeadsign(pattern),
                    direction: graph.patternDirection(pattern),
                    stopCount: stopCount,
                    tripCount: graph.patternTripCount(pattern),
                    firstStopName: graph.stopName(graph.patternStop(pattern, at: 0)),
                    lastStopName: graph.stopName(graph.patternStop(pattern, at: stopCount - 1))
                )
            )
        }
        guard !options.isEmpty else { return nil }

        // Busiest first inside a direction: the variant with the most trips is
        // the one a rider means when they say "the 42 towards town", and the
        // short-workings belong underneath it.
        options.sort { left, right in
            if left.direction != right.direction { return left.direction < right.direction }
            if left.tripCount != right.tripCount { return left.tripCount > right.tripCount }
            return left.stopCount > right.stopCount
        }

        let selected: PatternOption
        if let requestedPattern, let match = options.first(where: { $0.pattern == requestedPattern }) {
            selected = match
        } else if let best = options.max(by: { ($0.tripCount, $0.stopCount) < ($1.tripCount, $1.stopCount) }) {
            selected = best
        } else {
            return nil
        }

        let pattern = selected.pattern
        let stopCount = graph.patternStopCount(pattern)
        var stops: [PatternStopItem] = []
        stops.reserveCapacity(stopCount)
        for position in 0..<stopCount {
            let stop = graph.patternStop(pattern, at: position)
            guard graph.isValid(stop: stop) else { continue }
            stops.append(
                PatternStopItem(
                    position: position,
                    stop: stop,
                    name: graph.stopName(stop),
                    code: graph.stopCode(stop),
                    accessibility: graph.stopAccessibility(stop),
                    distanceMeters: graph.patternDistance(pattern, at: position)
                )
            )
        }
        guard !stops.isEmpty else { return nil }

        let mode = graph.routeMode(route)
        let displayName = graph.routeDisplayName(route)

        return PatternDetailData(
            pattern: pattern,
            route: route,
            routeIdentifier: graph.routeIdentifier(route),
            badge: LineBadgeData(
                text: displayName,
                backgroundHex: graph.routeColor(route),
                foregroundHex: graph.routeTextColor(route),
                mode: mode,
                accessibilityLabel: "\(TransitModeNaming.title(mode)) \(displayName)"
            ),
            mode: mode,
            routeLongName: graph.routeLongName(route),
            routeDescription: graph.routeDescription(route),
            agencyName: graph.agencyName(graph.routeAgency(route)),
            headsign: selected.headsign,
            direction: selected.direction,
            accessibility: graph.patternAccessibility(pattern),
            tripCount: selected.tripCount,
            stops: stops,
            options: options
        )
    }

    /// Every scheduled departure of one pattern from one stop on one service day.
    ///
    /// Built straight from the graph rather than through `TransitService`: the
    /// facade exposes `departures(atStop:)`, which is a *next departures* query
    /// bounded by a time window and a per-pattern cap, and a timetable needs the
    /// whole day. `DepartureBoardService.departures(pattern:at:on:realtime:)`
    /// does exactly this but is not surfaced on `TransitService`.
    ///
    /// Scheduled only — deliberately. A timetable for next Tuesday has no
    /// realtime to apply, and labelling it "live" would be a lie.
    nonisolated static func timetableSlots(
        pattern: PatternIndex,
        position: Int,
        date: ServiceDate,
        graph: TransitGraph
    ) -> [TimetableSlot] {
        guard pattern >= 0, Int(pattern) < graph.patternCount else { return [] }
        guard let dayIndex = graph.dayIndex(for: date) else { return [] }

        let stopCount = graph.patternStopCount(pattern)
        guard position >= 0, position < stopCount else { return [] }
        let isTerminus = position == stopCount - 1

        var slots: [TimetableSlot] = []
        slots.reserveCapacity(min(graph.patternTripCount(pattern), 512))

        for offset in 0..<graph.patternTripCount(pattern) {
            let trip = graph.globalTripIndex(pattern, offset: offset)
            guard graph.isServiceActive(graph.tripService(trip), dayIndex: dayIndex) else { continue }
            // The last stop has no departure; show the arrival instead, which is
            // what the rider on board wants to know.
            let seconds = isTerminus
                ? graph.arrivalTime(pattern: pattern, tripOffset: offset, position: position)
                : graph.departureTime(pattern: pattern, tripOffset: offset, position: position)
            guard seconds != noTime, seconds >= 0 else { continue }
            slots.append(
                TimetableSlot(trip: trip, seconds: seconds, accessibility: graph.tripAccessibility(trip))
            )
        }

        slots.sort { $0.seconds < $1.seconds }
        return slots
    }
}
