import Foundation

/// Turns RAPTOR's parent pointers back into something a rider can read.
///
/// The router never builds a journey while it searches — it only writes labels,
/// which is what keeps the inner loop free of allocation. Reconstruction happens
/// once per candidate result and walks the chain backwards: a ride label names
/// its pattern and the two positions along it, and hands off to the previous
/// round at the stop it boarded; a walk label hands off to the same round at the
/// stop it came from; a seed label ends the chain at the rider's own origin.
struct JourneyBuilder {
    let query: RaptorQuery
    let context: RaptorContext
    let originPoint: LegPoint
    let destinationPoint: LegPoint

    var graph: TransitGraph { query.graph }

    private func point(for stop: StopIndex) -> LegPoint {
        LegPoint(stop: stop, coordinate: graph.stopCoordinate(stop), name: graph.stopName(stop))
    }

    /// Reconstructs the journey that ends at `egress.stop` in `round`, or `nil`
    /// when the chain is incomplete — which can happen legitimately when a label
    /// was overwritten by a later, better one during the same range sweep.
    func journey(round: Int, egress: AccessPoint) -> Journey? {
        guard round >= 1, round < context.roundCount else { return nil }
        let finalLabel = context.label(round: round, stop: egress.stop)
        guard finalLabel.time != noTime else { return nil }

        // Built back-to-front, then reversed.
        var reversed: [JourneyLeg] = []
        reversed.reserveCapacity(round * 2 + 2)

        appendWalk(
            into: &reversed,
            origin: point(for: egress.stop),
            destination: destinationPoint,
            departure: finalLabel.time,
            arrival: finalLabel.time + egress.walkSeconds,
            meters: Double(egress.walkMeters)
        )

        var currentRound = round
        var currentStop = egress.stop
        // A chain can visit at most one ride and one footpath per round, plus the
        // seed; anything longer means the labels were mutated underneath us.
        var steps = 0
        let stepLimit = context.roundCount * 2 + 4

        while true {
            steps += 1
            guard steps <= stepLimit else { return nil }

            let label = context.label(round: currentRound, stop: currentStop)
            guard label.time != noTime else { return nil }

            if label.isRide {
                guard let ride = makeRide(label: label, alightStop: currentStop) else { return nil }
                reversed.append(.ride(ride))
                currentStop = ride.boardStop
                currentRound -= 1
                guard currentRound >= 0 else { return nil }
                continue
            }

            if label.linkStop != noIndex {
                let from = label.linkStop
                appendWalk(
                    into: &reversed,
                    origin: point(for: from),
                    destination: point(for: currentStop),
                    departure: label.time - label.legWalkSeconds,
                    arrival: label.time,
                    meters: Double(label.legWalkMeters)
                )
                currentStop = from
                continue
            }

            // Seed label: the rider's own starting point.
            appendWalk(
                into: &reversed,
                origin: originPoint,
                destination: point(for: currentStop),
                departure: label.time - label.legWalkSeconds,
                arrival: label.time,
                meters: Double(label.legWalkMeters)
            )
            break
        }

        let legs = merged(Array(reversed.reversed()))
        guard !legs.isEmpty, legs.contains(where: { $0.rideLeg != nil }) else { return nil }
        return Journey(legs: legs, baseDate: query.baseDate)
    }

    /// The pure-walk option. Riders get annoyed when an app hides the fact that
    /// the destination is four minutes away on foot, so this is always offered
    /// as a candidate when it fits inside the walking budget.
    func walkOnlyJourney(departure: Int32, meters: Double) -> Journey? {
        let seconds = query.options.walkingSeconds(forMeters: meters)
        let leg = WalkLeg(
            origin: originPoint, destination: destinationPoint,
            departure: departure, arrival: departure + seconds,
            distanceMeters: meters
        )
        return Journey(legs: [.walk(leg)], baseDate: query.baseDate)
    }

    // MARK: - Legs

    private func makeRide(label: RaptorLabel, alightStop: StopIndex) -> RideLeg? {
        let pattern = label.pattern
        guard pattern >= 0, Int(pattern) < graph.patternCount else { return nil }
        let positionCount = graph.patternStopCount(pattern)
        let boardPosition = Int(label.boardPosition)
        let alightPosition = Int(label.alightPosition)
        guard boardPosition >= 0, boardPosition < positionCount else { return nil }
        guard alightPosition > boardPosition, alightPosition < positionCount else { return nil }
        let tripOffset = Int(label.tripOffset)
        guard tripOffset >= 0, tripOffset < graph.patternTripCount(pattern) else { return nil }

        let trip = graph.globalTripIndex(pattern, offset: tripOffset)
        let shift = label.dayOffset * secondsPerServiceDay
        let scheduledDeparture = graph.departureTime(
            pattern: pattern, tripOffset: tripOffset, position: boardPosition
        ) + shift
        let scheduledArrival = graph.arrivalTime(
            pattern: pattern, tripOffset: tripOffset, position: alightPosition
        ) + shift

        var departureDelay: Int32?
        var arrivalDelay: Int32?
        if query.appliesRealtime {
            departureDelay = query.realtime.adjustment(trip: trip, position: boardPosition)?.departureDelay
            arrivalDelay = query.realtime.adjustment(trip: trip, position: alightPosition)?.arrivalDelay
        }

        return RideLeg(
            pattern: pattern,
            tripOffset: tripOffset,
            trip: trip,
            route: graph.patternRoute(pattern),
            boardPosition: boardPosition,
            alightPosition: alightPosition,
            boardStop: graph.patternStop(pattern, at: boardPosition),
            alightStop: alightStop,
            scheduledDeparture: scheduledDeparture,
            scheduledArrival: scheduledArrival,
            departureDelay: departureDelay,
            arrivalDelay: arrivalDelay,
            serviceDate: query.baseDate.adding(days: Int(label.dayOffset))
        )
    }

    /// Drops the degenerate zero-metre, zero-second walk that an endpoint which
    /// *is* a stop would otherwise produce.
    private func appendWalk(
        into legs: inout [JourneyLeg],
        origin: LegPoint, destination: LegPoint,
        departure: Int32, arrival: Int32, meters: Double
    ) {
        guard meters > 0 || arrival > departure else { return }
        legs.append(
            .walk(
                WalkLeg(
                    origin: origin, destination: destination,
                    departure: departure, arrival: arrival, distanceMeters: meters
                )
            )
        )
    }

    /// Collapses adjacent walk legs. A journey that ends with a footpath onto the
    /// egress stop followed by the egress walk is one walk to the rider, not two.
    private func merged(_ legs: [JourneyLeg]) -> [JourneyLeg] {
        var result: [JourneyLeg] = []
        result.reserveCapacity(legs.count)
        for leg in legs {
            if case .walk(let walk) = leg, let last = result.last, case .walk(let previous) = last {
                result[result.count - 1] = .walk(
                    WalkLeg(
                        origin: previous.origin,
                        destination: walk.destination,
                        departure: previous.departure,
                        arrival: walk.arrival,
                        distanceMeters: previous.distanceMeters + walk.distanceMeters
                    )
                )
            } else {
                result.append(leg)
            }
        }
        return result
    }
}
