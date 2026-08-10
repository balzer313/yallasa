import Foundation

/// Upcoming departures from a set of stops.
///
/// Deliberately not built on `JourneyPlanner`. A departures board is the screen
/// people open twenty times a day, often for one second, and it needs to be an
/// order of magnitude cheaper than a journey search: no rounds, no labels, no
/// reconstruction — just a binary search into each pattern's trip list and a
/// forward scan until the window closes.
///
/// Holds no mutable state, so one instance serves the whole app and several
/// queries may run at once against one graph.
public final class DepartureBoardService {
    private let graph: TransitGraph

    public init(graph: TransitGraph) {
        self.graph = graph
    }

    /// Upcoming departures across a set of stops, earliest first.
    ///
    /// `limitPerPattern` is what stops a board at a busy interchange from being
    /// twelve consecutive departures of the same line: riders want to know what
    /// their options *are*, and only then when each one goes.
    public func departures(
        from stops: [StopIndex],
        after instant: ServiceInstant,
        withinSeconds window: Int,
        limit: Int,
        limitPerPattern: Int,
        modes: Set<TransitMode>?,
        realtime: RealtimeSource
    ) -> [Departure] {
        let normalised = instant.normalised
        let queryDate = normalised.date
        guard let baseDayIndex = graph.dayIndex(for: queryDate) else { return [] }

        let from = normalised.seconds
        let until = from + Int32(clamping: max(0, window))

        var collected: [Departure] = []
        collected.reserveCapacity(min(limit * 4, 512))

        // A stop can appear on the same pattern twice (loop services), and two
        // stops in the list can share a pattern; without this the same physical
        // departure is offered several times.
        var seen = Set<Int64>()

        for stop in stops {
            guard graph.isValid(stop: stop) else { continue }

            for slot in graph.patternSlots(atStop: stop) {
                let pattern = graph.stopPatternReferences[slot]
                guard pattern >= 0, Int(pattern) < graph.patternCount else { continue }
                let position = Int(graph.stopPatternPositions[slot])

                // The last stop of a pattern is an arrival, not a departure, and
                // drop-off-only stops are not boardable.
                guard graph.patternAllowsBoarding(pattern, at: position) else { continue }

                if let modes, !modes.contains(graph.routeMode(graph.patternRoute(pattern))) {
                    continue
                }

                appendDepartures(
                    pattern: pattern,
                    position: position,
                    stop: stop,
                    from: from,
                    until: until,
                    baseDayIndex: baseDayIndex,
                    queryDate: queryDate,
                    realtime: realtime,
                    seen: &seen,
                    into: &collected
                )
            }
        }

        collected.sort { lhs, rhs in
            lhs.actualDeparture == rhs.actualDeparture
                ? lhs.id < rhs.id
                : lhs.actualDeparture < rhs.actualDeparture
        }

        guard limitPerPattern > 0 else { return Array(collected.prefix(limit)) }

        var perPattern: [PatternIndex: Int] = [:]
        var result: [Departure] = []
        result.reserveCapacity(min(limit, collected.count))
        for departure in collected {
            let count = perPattern[departure.pattern, default: 0]
            guard count < limitPerPattern else { continue }
            perPattern[departure.pattern] = count + 1
            result.append(departure)
            if result.count >= limit { break }
        }
        return result
    }

    /// Every departure of one pattern from one stop on a given service date — a
    /// line's printed timetable.
    public func departures(
        pattern: PatternIndex,
        at position: Int,
        on date: ServiceDate,
        realtime: RealtimeSource
    ) -> [Departure] {
        guard pattern >= 0, Int(pattern) < graph.patternCount else { return [] }
        guard position >= 0, position < graph.patternStopCount(pattern) else { return [] }
        guard let dayIndex = graph.dayIndex(for: date) else { return [] }

        let stop = graph.patternStop(pattern, at: position)
        let tripCount = graph.patternTripCount(pattern)
        var result: [Departure] = []
        result.reserveCapacity(min(tripCount, 256))

        // A timetable is for one service day only: no ±1 day sweep here, because
        // "Tuesday's timetable" means the trips whose service is Tuesday, even
        // the ones that run at 25:10.
        for offset in 0..<tripCount {
            let trip = graph.globalTripIndex(pattern, offset: offset)
            guard graph.isServiceActive(graph.tripService(trip), dayIndex: dayIndex) else { continue }
            let scheduled = graph.departureTime(pattern: pattern, tripOffset: offset, position: position)
            guard scheduled != noTime else { continue }

            let adjustment = realtime.adjustment(trip: trip, position: position)
            result.append(
                Departure(
                    stop: stop,
                    pattern: pattern,
                    tripOffset: offset,
                    trip: trip,
                    route: graph.patternRoute(pattern),
                    position: position,
                    scheduledDeparture: scheduled,
                    delay: adjustment.map { $0.departureDelay },
                    isCancelled: adjustment?.blocksBoarding ?? false,
                    serviceDate: date,
                    queryDate: date
                )
            )
        }

        result.sort { $0.scheduledDeparture < $1.scheduledDeparture }
        return result
    }

    // MARK: - Scanning

    private func appendDepartures(
        pattern: PatternIndex,
        position: Int,
        stop: StopIndex,
        from: ServiceSeconds,
        until: ServiceSeconds,
        baseDayIndex: Int,
        queryDate: ServiceDate,
        realtime: RealtimeSource,
        seen: inout Set<Int64>,
        into collected: inout [Departure]
    ) {
        let tripCount = graph.patternTripCount(pattern)
        guard tripCount > 0 else { return }
        let route = graph.patternRoute(pattern)

        // Yesterday's service still running after midnight, today's, and
        // tomorrow's for a window that crosses midnight. Skipping the −1 offset
        // is why so many hand-rolled boards go blank at half past midnight.
        for dayOffset in -1...1 {
            let dayIndex = baseDayIndex + dayOffset
            guard dayIndex >= 0, dayIndex < graph.metadata.calendarDayCount else { continue }

            let shift = Int32(dayOffset) * 86_400
            // Translate the window into this service day's own timetable frame
            // once, rather than translating every trip time into the query frame.
            let localFrom = from - shift
            let localUntil = until - shift
            // Realtime can only make a vehicle later, so a trip scheduled before
            // the window may still depart inside it. Nothing scheduled more than
            // an hour ago is worth considering.
            let searchFrom = realtime.coveredTripCount > 0 ? localFrom - 3_600 : localFrom

            var offset = firstTripOffset(
                pattern: pattern, position: position, departingAtOrAfter: searchFrom, tripCount: tripCount
            )

            while offset < tripCount {
                let scheduled = graph.departureTime(pattern: pattern, tripOffset: offset, position: position)
                if scheduled == noTime { offset += 1; continue }
                if scheduled > localUntil { break }

                let trip = graph.globalTripIndex(pattern, offset: offset)
                guard graph.isServiceActive(graph.tripService(trip), dayIndex: dayIndex) else {
                    offset += 1
                    continue
                }

                let adjustment = realtime.adjustment(trip: trip, position: position)
                let delay = adjustment?.departureDelay
                let blocked = adjustment?.blocksBoarding ?? false
                let actualLocal = scheduled + (blocked ? 0 : (delay ?? 0))

                // A cancelled service is still shown — a rider needs to know the
                // 09:12 is not coming, not just that it vanished from the board —
                // but only while it would still have been in the window.
                if actualLocal >= localFrom, actualLocal <= localUntil {
                    // Keyed on the physical departure, which is the trip, the
                    // position along it, and which service day it belongs to.
                    // A daily service yields the same trip at two day offsets;
                    // those are different buses 24 hours apart, not a duplicate.
                    let key = (Int64(trip) << 20) | (Int64(position) << 4) | Int64(dayOffset + 1)
                    if seen.insert(key).inserted {
                        collected.append(
                            Departure(
                                stop: stop,
                                pattern: pattern,
                                tripOffset: offset,
                                trip: trip,
                                route: route,
                                position: position,
                                scheduledDeparture: scheduled + shift,
                                delay: delay,
                                isCancelled: blocked,
                                serviceDate: queryDate.adding(days: dayOffset),
                                queryDate: queryDate
                            )
                        )
                    }
                }
                offset += 1
            }
        }
    }

    /// First trip offset whose scheduled departure at `position` is at or after
    /// `time`.
    ///
    /// Valid because the importer guarantees trips within a pattern are ordered
    /// by departure at *every* position, not merely the first — that is what the
    /// overtaking split exists to preserve.
    private func firstTripOffset(
        pattern: PatternIndex,
        position: Int,
        departingAtOrAfter time: ServiceSeconds,
        tripCount: Int
    ) -> Int {
        var low = 0
        var high = tripCount
        while low < high {
            let middle = (low + high) / 2
            let value = graph.departureTime(pattern: pattern, tripOffset: middle, position: position)
            if value < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
