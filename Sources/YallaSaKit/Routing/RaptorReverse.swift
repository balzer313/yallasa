import Foundation

/// A trip found by the backward timetable search.
struct RaptorReverseTripCandidate {
    var tripOffset: Int32
    var dayOffset: Int32
    var trip: TripIndex
    /// Realtime-adjusted arrival at the scanned position, in query-frame seconds.
    var arrival: Int32
}

/// The backward, latest-departure RAPTOR search — the exact mirror of
/// `ForwardRaptor`.
///
/// A label is the *latest* moment the rider can still be standing at a stop and
/// reach the destination in time, using at most `round` further vehicle legs.
/// Every comparison flips: `min` becomes `max`, "earliest trip departing after"
/// becomes "latest trip arriving before", and patterns are walked from their far
/// end towards their start.
///
/// One asymmetry is worth naming: the graph stores footpaths as an out-edge list
/// per stop, and the backward search needs in-edges. It reuses the out-edge list
/// and assumes footpaths are symmetric. Generated footpaths are symmetric by
/// construction and `transfers.txt` entries almost always are; the alternative
/// is a second, reversed CSR in every graph file, which is not worth the bytes.
struct BackwardRaptor {
    let query: RaptorQuery
    let context: RaptorContext

    var graph: TransitGraph { query.graph }

    /// The sentinel a backward label reads as before it is set.
    static let unreachable: Int32 = Int32.min

    // MARK: - Seeding

    /// Plants round-0 labels: the latest moment the rider may leave each egress
    /// stop on foot and still be at the destination by `arrival`.
    func seed(egressPoints: [AccessPoint], arrival: Int32) {
        for point in egressPoints {
            guard point.walkMeters <= query.maximumWalkMeters else { continue }
            let latest = arrival - point.walkSeconds
            guard latest > context.best(stop: point.stop) else { continue }
            var label = RaptorLabel()
            label.time = latest
            label.walkMeters = point.walkMeters
            label.pattern = noIndex
            label.linkStop = noIndex
            label.legWalkSeconds = point.walkSeconds
            label.legWalkMeters = point.walkMeters
            label.lastRidePattern = noIndex
            context.setLabel(label, round: 0, stop: point.stop)
            context.setBest(latest, stop: point.stop)
            context.mark(stop: point.stop)
        }
    }

    // MARK: - Rounds

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

    /// The latest moment the rider can leave the origin, over every access stop
    /// and every round. `nil` when the destination is not reachable at all.
    func latestDeparture(from accessPoints: [AccessPoint], maximumRound: Int) -> Int32? {
        var best: Int32?
        for round in 1...max(1, maximumRound) where round < context.roundCount {
            for point in accessPoints {
                guard point.walkMeters <= query.maximumWalkMeters else { continue }
                let label = context.label(round: round, stop: point.stop)
                guard label.time != BackwardRaptor.unreachable else { continue }
                let departure = label.time - point.walkSeconds
                if let found = best {
                    if departure > found { best = departure }
                } else {
                    best = departure
                }
            }
        }
        return best
    }

    // MARK: - Pattern scanning

    private func scanPatterns(round: Int) {
        // Backward, so a pattern is entered at the *latest* marked position and
        // walked towards its first stop.
        context.buildQueue(preferLater: true)
        context.clearMarks()

        for pattern in context.queuedPatterns {
            guard query.allows(pattern: pattern) else { continue }
            guard context.dayMask(forPattern: pattern, baseDayIndex: query.baseDayIndex) != 0 else { continue }

            let positionCount = graph.patternStopCount(pattern)
            let lastPosition = context.queuedPosition(of: pattern)
            guard lastPosition >= 0, lastPosition < positionCount else { continue }
            context.statistics.patternsScanned += 1

            var tripOffset: Int32 = -1
            var tripDayOffset: Int32 = 0
            var trip: TripIndex = noIndex
            var alightPosition: Int32 = -1
            var alightLabel = RaptorLabel()

            var position = lastPosition
            while position >= 0 {
                defer { position -= 1 }
                let stop = graph.patternStop(pattern, at: position)
                guard stop >= 0, Int(stop) < context.stopCount else { continue }

                // (a) On a trip: boarding here is the latest way to be at this stop.
                if tripOffset >= 0, graph.patternAllowsBoarding(pattern, at: position) {
                    improveDeparture(
                        pattern: pattern, position: position, stop: stop, round: round,
                        tripOffset: tripOffset, tripDayOffset: tripDayOffset, trip: trip,
                        alightPosition: alightPosition, alightLabel: alightLabel
                    )
                }

                // (b) Can the previous round let me stay on a *later* trip by
                //     alighting here instead?
                guard graph.patternAllowsAlighting(pattern, at: position) else { continue }
                let next = context.label(round: round - 1, stop: stop)
                guard next.time != BackwardRaptor.unreachable else { continue }
                guard next.walkMeters <= query.maximumWalkMeters else { continue }

                let needsSlack = next.lastRidePattern != noIndex && next.lastRidePattern != pattern
                let deadline = next.time - (needsSlack ? query.minimumTransferSeconds : 0)

                var currentArrival = BackwardRaptor.unreachable
                if tripOffset >= 0 {
                    currentArrival = effectiveArrival(
                        pattern: pattern, tripOffset: tripOffset, dayOffset: tripDayOffset,
                        position: position, trip: trip
                    )
                    guard deadline >= currentArrival else { continue }
                }

                guard let candidate = latestTrip(pattern: pattern, position: position, before: deadline) else {
                    continue
                }
                if tripOffset < 0 || candidate.arrival > currentArrival {
                    tripOffset = candidate.tripOffset
                    tripDayOffset = candidate.dayOffset
                    trip = candidate.trip
                    alightPosition = Int32(position)
                    alightLabel = next
                }
            }
        }
    }

    private func improveDeparture(
        pattern: PatternIndex, position: Int, stop: StopIndex, round: Int,
        tripOffset: Int32, tripDayOffset: Int32, trip: TripIndex,
        alightPosition: Int32, alightLabel: RaptorLabel
    ) {
        let scheduled = graph.departureTime(pattern: pattern, tripOffset: Int(tripOffset), position: position)
        guard scheduled != noTime else { return }
        var delay: Int32 = 0
        if query.appliesRealtime, let adjustment = query.realtime.adjustment(trip: trip, position: position) {
            if adjustment.blocksBoarding { return }
            delay = adjustment.departureDelay
        }
        let departure = scheduled + delay + tripDayOffset * secondsPerServiceDay
        guard departure > context.best(stop: stop) else { return }

        var label = RaptorLabel()
        label.time = departure
        label.walkMeters = alightLabel.walkMeters
        label.pattern = pattern
        label.tripOffset = tripOffset
        label.dayOffset = tripDayOffset
        label.boardPosition = Int32(position)
        label.alightPosition = alightPosition
        label.linkStop = noIndex
        label.lastRidePattern = pattern
        context.setLabel(label, round: round, stop: stop)
        context.setBest(departure, stop: stop)
        context.mark(stop: stop)
        context.statistics.stopsImproved += 1
    }

    // MARK: - Footpaths

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
                let latest = source.time - seconds
                guard latest > context.best(stop: target) else { continue }

                var label = RaptorLabel()
                label.time = latest
                label.walkMeters = totalWalk
                label.pattern = noIndex
                // Backward: the stop this walk leads *to*.
                label.linkStop = source.stop
                label.legWalkSeconds = seconds
                label.legWalkMeters = meters
                label.lastRidePattern = source.lastRidePattern
                context.setLabel(label, round: round, stop: target)
                context.setBest(latest, stop: target)
                context.mark(stop: target)
                context.statistics.stopsImproved += 1
            }
        }
    }

    // MARK: - Timetable search

    func effectiveArrival(
        pattern: PatternIndex, tripOffset: Int32, dayOffset: Int32, position: Int, trip: TripIndex
    ) -> Int32 {
        let scheduled = graph.arrivalTime(pattern: pattern, tripOffset: Int(tripOffset), position: position)
        guard scheduled != noTime else { return BackwardRaptor.unreachable }
        var delay: Int32 = 0
        if query.appliesRealtime, let adjustment = query.realtime.adjustment(trip: trip, position: position) {
            if adjustment.isCancelled || adjustment.isSkipped { return BackwardRaptor.unreachable }
            delay = adjustment.arrivalDelay
        }
        return scheduled + delay + dayOffset * secondsPerServiceDay
    }

    /// The latest trip of `pattern` that reaches `position` no later than
    /// `deadline`, across the previous, current and next service day.
    func latestTrip(pattern: PatternIndex, position: Int, before deadline: Int32) -> RaptorReverseTripCandidate? {
        let mask = context.dayMask(forPattern: pattern, baseDayIndex: query.baseDayIndex)
        guard mask != 0 else { return nil }
        let tripCount = graph.patternTripCount(pattern)
        guard tripCount > 0 else { return nil }

        var best: RaptorReverseTripCandidate?

        for dayOffset in -1...1 {
            guard mask & UInt8(1 << (dayOffset + 1)) != 0 else { continue }
            let day = query.baseDayIndex + dayOffset
            guard day >= 0, day < graph.metadata.calendarDayCount else { continue }
            let shift = Int32(dayOffset) * secondsPerServiceDay

            // Mirror of the forward lookback: a vehicle running early arrives
            // sooner than its timetable says, so look a little past the deadline.
            let wanted = Int64(deadline) - Int64(shift) + Int64(query.realtimeLookbackSeconds)
            if wanted < Int64(Int32.min) { continue }
            let target = Int32(clamping: wanted)

            // First index whose arrival exceeds the target; everything usable is
            // strictly before it.
            var low = 0
            var high = tripCount
            while low < high {
                let middle = (low + high) / 2
                if graph.arrivalTime(pattern: pattern, tripOffset: middle, position: position) <= target {
                    low = middle + 1
                } else {
                    high = middle
                }
            }

            var offset = low - 1
            while offset >= 0 {
                defer { offset -= 1 }
                let scheduled = graph.arrivalTime(pattern: pattern, tripOffset: offset, position: position)
                if scheduled == noTime { continue }
                let scheduledInFrame = scheduled + shift
                if let found = best, scheduledInFrame < found.arrival { break }

                context.statistics.tripSegmentsScanned += 1
                let trip = graph.globalTripIndex(pattern, offset: offset)
                guard graph.isServiceActive(graph.tripService(trip), dayIndex: day) else { continue }
                if query.options.requiresWheelchairAccess, graph.tripAccessibility(trip) != .accessible { continue }

                var arrival = scheduledInFrame
                if query.appliesRealtime {
                    if query.realtime.isCancelled(trip: trip) { continue }
                    if let adjustment = query.realtime.adjustment(trip: trip, position: position) {
                        if adjustment.blocksBoarding { continue }
                        arrival = scheduledInFrame + adjustment.arrivalDelay
                    }
                }
                guard arrival <= deadline else { continue }
                let candidate = RaptorReverseTripCandidate(
                    tripOffset: Int32(offset), dayOffset: Int32(dayOffset), trip: trip, arrival: arrival
                )
                if let found = best {
                    if arrival > found.arrival { best = candidate }
                } else {
                    best = candidate
                }
            }
        }
        return best
    }
}
