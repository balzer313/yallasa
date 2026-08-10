import Foundation

/// Seconds in a nominal service day. GTFS times past this value are legal and
/// mean "after midnight, still the previous service day"; the router folds that
/// into a single query-relative frame rather than normalising them away.
let secondsPerServiceDay: Int32 = 86_400

/// One end of a journey, resolved to a stop plus the walk that reaches it.
struct AccessPoint {
    var stop: StopIndex
    var walkSeconds: Int32
    var walkMeters: Int32
}

/// The immutable half of a query. Everything here is read-only for the whole
/// search, which is what lets two tasks plan against one graph at once: the only
/// mutable state is the `RaptorContext` each of them owns.
struct RaptorQuery {
    let graph: TransitGraph
    let options: PlanOptions
    let realtime: RealtimeSource
    /// Midnight of this date is time zero for every label in the search.
    let baseDate: ServiceDate
    let baseDayIndex: Int

    let maximumWalkMeters: Int32
    let minimumTransferSeconds: Int32
    /// How far *before* the wanted time the trip search starts looking.
    ///
    /// The binary search is on the timetable, but realtime moves a vehicle off
    /// the timetable: a bus scheduled at 09:00 running eight minutes late is the
    /// one you catch at 09:05, and a search that started at 09:05 would never
    /// look at it. Zero when there is no realtime to apply, so the common case
    /// pays nothing.
    let realtimeLookbackSeconds: Int32

    init(graph: TransitGraph, options: PlanOptions, realtime: RealtimeSource, baseDate: ServiceDate, baseDayIndex: Int) {
        self.graph = graph
        self.options = options
        self.realtime = realtime
        self.baseDate = baseDate
        self.baseDayIndex = baseDayIndex
        self.maximumWalkMeters = Int32(max(0, min(options.maximumTotalWalkMeters, 2_000_000)).rounded())
        self.minimumTransferSeconds = Int32(max(0, options.minimumTransferSeconds))
        let usesRealtime = options.usesRealtime && realtime.coveredTripCount > 0
        self.realtimeLookbackSeconds = usesRealtime ? 1800 : 0
    }

    var appliesRealtime: Bool { options.usesRealtime }

    /// Whether the router may use this pattern at all, given the mode filter.
    func allows(pattern: PatternIndex) -> Bool {
        guard options.allowedModes != nil else { return true }
        return options.allows(mode: graph.routeMode(graph.patternRoute(pattern)))
    }
}

/// A trip found by the timetable search, already translated into the query frame.
struct RaptorTripCandidate {
    var tripOffset: Int32
    var dayOffset: Int32
    var trip: TripIndex
    /// Realtime-adjusted departure, in query-frame seconds.
    var departure: Int32
}

/// The forward, earliest-arrival RAPTOR search.
///
/// Round `k` holds the best arrival reachable using exactly `k` vehicle legs (or
/// fewer — a label is never copied forward, so a stop with no round-`k` label is
/// simply not improvable with `k` legs). Round 0 is access on foot only.
struct ForwardRaptor {
    let query: RaptorQuery
    let context: RaptorContext

    var graph: TransitGraph { query.graph }

    // MARK: - Seeding

    /// Plants round-0 labels for a single departure time.
    ///
    /// Called once per range-RAPTOR iteration. Because the sweep runs from the
    /// latest departure to the earliest, every call strictly improves the access
    /// labels, so the labels left over from the previous iteration are a valid
    /// starting point rather than something that has to be cleared.
    func seed(accessPoints: [AccessPoint], departure: Int32) {
        for point in accessPoints {
            guard point.walkMeters <= query.maximumWalkMeters else { continue }
            let arrival = departure + point.walkSeconds
            guard arrival < context.best(stop: point.stop) else { continue }
            var label = RaptorLabel()
            label.time = arrival
            label.walkMeters = point.walkMeters
            label.pattern = noIndex
            label.linkStop = noIndex
            label.legWalkSeconds = point.walkSeconds
            label.legWalkMeters = point.walkMeters
            label.lastRidePattern = noIndex
            context.setLabel(label, round: 0, stop: point.stop)
            context.setBest(arrival, stop: point.stop)
            context.mark(stop: point.stop)
        }
    }

    // MARK: - Rounds

    /// Runs rounds until nothing improves, the transfer limit is reached, or the
    /// time budget expires. Returns the highest round that produced a label.
    @discardableResult
    func run() -> Int {
        var lastProductiveRound = 0
        for round in 1..<context.roundCount {
            if context.markedStops.isEmpty { break }
            if context.checkDeadline() { break }
            scanPatterns(round: round)
            relaxTransfers(round: round)
            if context.statistics.rounds < round { context.statistics.rounds = round }
            if context.markedStops.isEmpty { break }
            lastProductiveRound = round
        }
        return lastProductiveRound
    }

    // MARK: - Pattern scanning

    private func scanPatterns(round: Int) {
        context.buildQueue(preferLater: false)
        // The queue captured everything the previous round marked; the marks
        // themselves now belong to this round's output.
        context.clearMarks()

        let patterns = context.queuedPatterns
        for pattern in patterns {
            guard query.allows(pattern: pattern) else { continue }
            guard context.dayMask(forPattern: pattern, baseDayIndex: query.baseDayIndex) != 0 else { continue }

            let positionCount = graph.patternStopCount(pattern)
            let firstPosition = context.queuedPosition(of: pattern)
            guard firstPosition >= 0, firstPosition < positionCount else { continue }
            context.statistics.patternsScanned += 1

            // "The trip I am currently on", or none.
            var tripOffset: Int32 = -1
            var tripDayOffset: Int32 = 0
            var trip: TripIndex = noIndex
            var boardPosition: Int32 = -1
            var boardLabel = RaptorLabel()

            for position in firstPosition..<positionCount {
                let stop = graph.patternStop(pattern, at: position)
                guard stop >= 0, Int(stop) < context.stopCount else { continue }

                // (a) Riding: can this trip improve the arrival here?
                if tripOffset >= 0, graph.patternAllowsAlighting(pattern, at: position) {
                    improveArrival(
                        pattern: pattern, position: position, stop: stop, round: round,
                        tripOffset: tripOffset, tripDayOffset: tripDayOffset, trip: trip,
                        boardPosition: boardPosition, boardLabel: boardLabel
                    )
                }

                // (b) Boarding: does the previous round put me here early enough
                // to catch something earlier than what I am on?
                guard graph.patternAllowsBoarding(pattern, at: position) else { continue }
                let previous = context.label(round: round - 1, stop: stop)
                guard previous.time != noTime else { continue }
                guard previous.walkMeters <= query.maximumWalkMeters else { continue }

                // No transfer slack on the first boarding of a journey, and none
                // for staying on (or returning to) the same line.
                let needsSlack = previous.lastRidePattern != noIndex && previous.lastRidePattern != pattern
                let ready = previous.time + (needsSlack ? query.minimumTransferSeconds : 0)

                var currentDeparture = noTime
                if tripOffset >= 0 {
                    currentDeparture = effectiveDeparture(
                        pattern: pattern, tripOffset: tripOffset, dayOffset: tripDayOffset,
                        position: position, trip: trip
                    )
                    guard ready <= currentDeparture else { continue }
                }

                guard let candidate = earliestTrip(pattern: pattern, position: position, after: ready) else {
                    continue
                }
                if tripOffset < 0 || candidate.departure < currentDeparture {
                    tripOffset = candidate.tripOffset
                    tripDayOffset = candidate.dayOffset
                    trip = candidate.trip
                    boardPosition = Int32(position)
                    boardLabel = previous
                }
            }
        }
    }

    private func improveArrival(
        pattern: PatternIndex, position: Int, stop: StopIndex, round: Int,
        tripOffset: Int32, tripDayOffset: Int32, trip: TripIndex,
        boardPosition: Int32, boardLabel: RaptorLabel
    ) {
        let scheduled = graph.arrivalTime(pattern: pattern, tripOffset: Int(tripOffset), position: position)
        guard scheduled != noTime else { return }
        var delay: Int32 = 0
        if query.appliesRealtime, let adjustment = query.realtime.adjustment(trip: trip, position: position) {
            // A vehicle that skips this stop cannot let anyone off at it.
            if adjustment.isCancelled || adjustment.isSkipped { return }
            delay = adjustment.arrivalDelay
        }
        let arrival = scheduled + delay + tripDayOffset * secondsPerServiceDay
        guard arrival < context.best(stop: stop) else { return }

        var label = RaptorLabel()
        label.time = arrival
        label.walkMeters = boardLabel.walkMeters
        label.pattern = pattern
        label.tripOffset = tripOffset
        label.dayOffset = tripDayOffset
        label.boardPosition = boardPosition
        label.alightPosition = Int32(position)
        label.linkStop = noIndex
        label.lastRidePattern = pattern
        context.setLabel(label, round: round, stop: stop)
        context.setBest(arrival, stop: stop)
        context.mark(stop: stop)
        context.statistics.stopsImproved += 1
    }

    // MARK: - Footpaths

    /// Relaxes the graph's transitively-closed footpaths out of every stop this
    /// round improved. One pass, from a snapshot, deliberately non-chaining.
    private func relaxTransfers(round: Int) {
        context.snapshotTransferSources(round: round)
        for source in context.pendingTransferSources {
            for slot in graph.transferSlots(fromStop: source.stop) {
                let target = graph.transferTargets[slot]
                guard target >= 0, Int(target) < context.stopCount, target != source.stop else { continue }
                let seconds = graph.transferSecondsColumn[slot]
                guard seconds >= 0 else { continue }
                let meters = max(graph.transferMetersColumn[slot], 0)
                let totalWalk = source.walkMeters + meters
                guard totalWalk <= query.maximumWalkMeters else { continue }
                let arrival = source.time + seconds
                guard arrival < context.best(stop: target) else { continue }

                var label = RaptorLabel()
                label.time = arrival
                label.walkMeters = totalWalk
                label.pattern = noIndex
                label.linkStop = source.stop
                label.legWalkSeconds = seconds
                label.legWalkMeters = meters
                label.lastRidePattern = source.lastRidePattern
                context.setLabel(label, round: round, stop: target)
                context.setBest(arrival, stop: target)
                context.mark(stop: target)
                context.statistics.stopsImproved += 1
            }
        }
    }

    // MARK: - Timetable search

    /// Realtime-adjusted departure of a known trip at a position, in query frame.
    func effectiveDeparture(
        pattern: PatternIndex, tripOffset: Int32, dayOffset: Int32, position: Int, trip: TripIndex
    ) -> Int32 {
        let scheduled = graph.departureTime(pattern: pattern, tripOffset: Int(tripOffset), position: position)
        guard scheduled != noTime else { return noTime }
        var delay: Int32 = 0
        if query.appliesRealtime, let adjustment = query.realtime.adjustment(trip: trip, position: position),
           !adjustment.blocksBoarding {
            delay = adjustment.departureDelay
        }
        return scheduled + delay + dayOffset * secondsPerServiceDay
    }

    /// The earliest trip of `pattern` boardable at `position` no earlier than
    /// `after`, considering the previous, current and next service day.
    ///
    /// Everything is compared in the query frame, so a trip that belongs to
    /// yesterday's service and runs at 25:10 is simply a trip at 01:10 today.
    /// The three offsets are tried independently and the best wins; a pattern
    /// with no service on one of them is skipped through the cached day mask
    /// rather than by scanning its trips again.
    func earliestTrip(pattern: PatternIndex, position: Int, after ready: Int32) -> RaptorTripCandidate? {
        let mask = context.dayMask(forPattern: pattern, baseDayIndex: query.baseDayIndex)
        guard mask != 0 else { return nil }
        let tripCount = graph.patternTripCount(pattern)
        guard tripCount > 0 else { return nil }

        var best: RaptorTripCandidate?

        for dayOffset in -1...1 {
            guard mask & UInt8(1 << (dayOffset + 1)) != 0 else { continue }
            let day = query.baseDayIndex + dayOffset
            guard day >= 0, day < graph.metadata.calendarDayCount else { continue }
            let shift = Int32(dayOffset) * secondsPerServiceDay

            // Wanted time expressed in the timetable's own frame, backed off by
            // the realtime lookback so a delayed early trip is still considered.
            let wanted = Int64(ready) - Int64(shift) - Int64(query.realtimeLookbackSeconds)
            if wanted > Int64(Int32.max) { continue }
            let target = Int32(clamping: wanted)

            // Trips are sorted by departure at *every* position — the importer
            // splits overtaking trips into their own pattern precisely so this
            // binary search is legal here and not only at position 0.
            var low = 0
            var high = tripCount
            while low < high {
                let middle = (low + high) / 2
                if graph.departureTime(pattern: pattern, tripOffset: middle, position: position) < target {
                    low = middle + 1
                } else {
                    high = middle
                }
            }

            for offset in low..<tripCount {
                let scheduled = graph.departureTime(pattern: pattern, tripOffset: offset, position: position)
                if scheduled == noTime { continue }
                let scheduledInFrame = scheduled + shift
                // Later trips only depart later, so once one candidate is in
                // hand nothing scheduled after it can beat it.
                if let found = best, scheduledInFrame > found.departure { break }

                context.statistics.tripSegmentsScanned += 1
                let trip = graph.globalTripIndex(pattern, offset: offset)
                guard graph.isServiceActive(graph.tripService(trip), dayIndex: day) else { continue }
                if query.options.requiresWheelchairAccess, graph.tripAccessibility(trip) != .accessible { continue }

                var departure = scheduledInFrame
                if query.appliesRealtime {
                    if query.realtime.isCancelled(trip) { continue }
                    if let adjustment = query.realtime.adjustment(trip: trip, position: position) {
                        if adjustment.blocksBoarding { continue }
                        departure = scheduledInFrame + adjustment.departureDelay
                    }
                }
                guard departure >= ready else { continue }
                let candidate = RaptorTripCandidate(
                    tripOffset: Int32(offset), dayOffset: Int32(dayOffset), trip: trip, departure: departure
                )
                if let found = best {
                    if departure < found.departure { best = candidate }
                } else {
                    best = candidate
                }
            }
        }
        return best
    }
}
