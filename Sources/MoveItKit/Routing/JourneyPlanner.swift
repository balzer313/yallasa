import Foundation

/// Door-to-door journey planning.
///
/// Holds nothing but the graph. Every piece of mutable state a search needs
/// lives in a `RaptorContext` created for that search, so one planner serves the
/// whole app and two tasks may plan at once against one graph.
public final class JourneyPlanner {
    private let graph: TransitGraph

    /// How many distinct departure times a range search will try. Each one is a
    /// full RAPTOR run, so this is the knob that trades result richness against
    /// the wall-clock budget; the budget itself is the real backstop.
    private static let maximumRangeIterations = 12

    /// Access and egress stop fan-out. Beyond a couple of dozen the extra stops
    /// are further away than the ones already found and almost never change the
    /// answer, while every one of them costs pattern scans in round 1.
    private static let maximumEndpointStops = 24

    public init(graph: TransitGraph) {
        self.graph = graph
    }

    public func plan(
        _ request: PlanRequest,
        realtime: RealtimeSource = EmptyRealtimeSource.shared
    ) throws -> PlanResult {
        let options = request.options
        let anchor = request.anchor.instant.normalised
        let baseDate = anchor.date

        guard let baseDayIndex = graph.dayIndex(for: baseDate) else {
            throw PlanError.dateNotCovered(baseDate)
        }

        if case .stop(let a) = request.origin, case .stop(let b) = request.destination, a == b {
            throw PlanError.trivialJourney
        }

        let effectiveRealtime: RealtimeSource = options.usesRealtime ? realtime : EmptyRealtimeSource.shared

        guard let origin = resolve(
            request.origin, walkLimitMeters: options.maximumAccessWalkMeters, options: options
        ) else {
            throw PlanError.noStopsNearOrigin
        }
        guard let destination = resolve(
            request.destination, walkLimitMeters: options.maximumEgressWalkMeters, options: options
        ) else {
            throw PlanError.noStopsNearDestination
        }

        let query = RaptorQuery(
            graph: graph,
            options: options,
            realtime: effectiveRealtime,
            baseDate: baseDate,
            baseDayIndex: baseDayIndex
        )
        let context = RaptorContext(graph: graph, maximumTransfers: options.maximumTransfers)
        let forward = ForwardRaptor(query: query, context: context)
        let builder = JourneyBuilder(
            query: query,
            context: context,
            originPoint: origin.legPoint,
            destinationPoint: destination.legPoint
        )

        var statistics = PlanStatistics()
        let started = Date()
        var found: [String: Journey] = [:]

        // A pure walk is a legitimate answer for a short hop, and riders resent
        // an app that hides it behind a two-stop bus ride. Computed up front so
        // it survives a router that runs out of budget.
        let walkDistance = origin.legPoint.coordinate.distance(to: destination.legPoint.coordinate)
        let walkSeconds = options.walkingSeconds(forMeters: walkDistance)
        var walkOnlyDeparture = anchor.seconds
        if request.anchor.isArriveBy { walkOnlyDeparture = anchor.seconds - walkSeconds }
        if walkDistance <= options.maximumTotalWalkMeters,
           let walkJourney = builder.walkOnlyJourney(departure: walkOnlyDeparture, meters: walkDistance) {
            found[walkJourney.id] = walkJourney
        }

        // The deadline a result must beat, for an arrive-by search.
        let arrivalDeadline: ServiceSeconds? = request.anchor.isArriveBy ? anchor.seconds : nil

        var searchWindowStart = anchor.seconds
        var searchWindowEnd = anchor.seconds + ServiceSeconds(clamping: options.searchWindowSeconds)

        if request.anchor.isArriveBy {
            // Work backwards from the destination first, purely to learn the
            // latest moment the rider may leave. Reconstruction then happens on a
            // normal forward search from that time, which keeps one code path for
            // building journeys instead of a mirrored second one.
            let backwardContext = RaptorContext(graph: graph, maximumTransfers: options.maximumTransfers)
            backwardContext.begin(forward: false, timeLimitSeconds: options.timeLimitSeconds * 0.4)
            let backward = BackwardRaptor(query: query, context: backwardContext)
            backward.seed(egressPoints: destination.points, arrival: anchor.seconds)
            let lastRound = backward.run()
            statistics.absorb(backwardContext.statistics)

            guard let latestDeparture = backward.latestDeparture(
                from: origin.points, maximumRound: lastRound
            ) else {
                return finish(
                    found: found, options: options, baseDate: baseDate,
                    statistics: &statistics, started: started, hitLimit: backwardContext.hitTimeLimit
                )
            }
            searchWindowEnd = latestDeparture
            searchWindowStart = latestDeparture - ServiceSeconds(clamping: options.searchWindowSeconds)
        }

        let candidates = candidateDepartures(
            accessPoints: origin.points,
            earliest: searchWindowStart,
            latest: searchWindowEnd,
            baseDayIndex: baseDayIndex,
            options: options,
            realtime: effectiveRealtime,
            limit: JourneyPlanner.maximumRangeIterations,
            preferLatest: request.anchor.isArriveBy
        )

        guard !candidates.isEmpty else {
            return finish(
                found: found, options: options, baseDate: baseDate,
                statistics: &statistics, started: started, hitLimit: false
            )
        }

        // The single most important answer — the earliest arrival for a
        // "leave now" search, or the latest feasible departure for an "arrive by"
        // one — is computed first and on its own generation, so that a search
        // which runs out of budget still returns it. Everything after this is
        // alternatives.
        let primary = request.anchor.isArriveBy ? candidates[candidates.count - 1] : candidates[0]
        let remainingBudget = { max(0.05, options.timeLimitSeconds - Date().timeIntervalSince(started)) }

        context.begin(forward: true, timeLimitSeconds: remainingBudget())
        forward.seed(accessPoints: origin.points, departure: primary)
        forward.run()
        statistics.departuresProbed += 1
        collect(
            builder: builder, context: context, egressPoints: destination.points,
            arrivalDeadline: arrivalDeadline, options: options, into: &found
        )
        statistics.absorb(context.statistics)
        var hitLimit = context.hitTimeLimit

        // Alternatives, swept from the latest departure down to the earliest.
        // Going downwards is what lets each iteration reuse the labels of the one
        // before it: an earlier departure can only ever improve an arrival, so
        // nothing left over from the previous sweep is stale.
        let alternatives = candidates.filter { $0 != primary }.sorted(by: >)
        if !alternatives.isEmpty, !hitLimit {
            context.begin(forward: true, timeLimitSeconds: remainingBudget())
            for departure in alternatives {
                if context.checkDeadline() { break }
                forward.seed(accessPoints: origin.points, departure: departure)
                forward.run()
                statistics.departuresProbed += 1
                collect(
                    builder: builder, context: context, egressPoints: destination.points,
                    arrivalDeadline: arrivalDeadline, options: options, into: &found
                )
            }
            statistics.absorb(context.statistics)
            hitLimit = hitLimit || context.hitTimeLimit
        }

        return finish(
            found: found, options: options, baseDate: baseDate,
            statistics: &statistics, started: started, hitLimit: hitLimit
        )
    }

    // MARK: - Endpoint resolution

    private struct ResolvedEndpoint {
        var points: [AccessPoint]
        var legPoint: LegPoint
    }

    private func resolve(
        _ endpoint: PlanEndpoint,
        walkLimitMeters: Double,
        options: PlanOptions
    ) -> ResolvedEndpoint? {
        switch endpoint {
        case .stop(let stop):
            guard graph.isValid(stop: stop) else { return nil }
            let coordinate = graph.stopCoordinate(stop)
            let legPoint = LegPoint(stop: stop, coordinate: coordinate, name: graph.stopName(stop))

            var points: [AccessPoint] = []
            if !graph.stopIsStation(stop) {
                points.append(AccessPoint(stop: stop, walkSeconds: 0, walkMeters: 0))
            }
            // A station record carries no patterns of its own — the trains call
            // at its platforms. Asking to depart "from Penn Station" has to mean
            // its children, or the search starts from a stop nothing serves.
            let station = graph.stopStation(stop)
            for nearby in graph.stops(near: coordinate, radiusMeters: 400, limit: 24) {
                guard nearby.stop != stop, graph.stopStation(nearby.stop) == station else { continue }
                points.append(
                    AccessPoint(
                        stop: nearby.stop,
                        walkSeconds: options.walkingSeconds(forMeters: nearby.distanceMeters),
                        walkMeters: Int32(nearby.distanceMeters.rounded())
                    )
                )
            }
            guard !points.isEmpty else { return nil }
            return ResolvedEndpoint(points: points, legPoint: legPoint)

        case .coordinate(let coordinate):
            guard coordinate.isValid else { return nil }
            var nearby = graph.stops(
                near: coordinate,
                radiusMeters: max(walkLimitMeters, 100),
                limit: JourneyPlanner.maximumEndpointStops
            )
            if nearby.isEmpty {
                // Somewhere with sparse coverage: rather than refuse outright,
                // reach further and let the walking-budget filter decide.
                nearby = graph.nearestStops(to: coordinate, limit: 6, maximumRadiusMeters: 5000)
            }
            guard !nearby.isEmpty else { return nil }

            let points = nearby.map { candidate in
                AccessPoint(
                    stop: candidate.stop,
                    walkSeconds: options.walkingSeconds(forMeters: candidate.distanceMeters),
                    walkMeters: Int32(candidate.distanceMeters.rounded())
                )
            }
            return ResolvedEndpoint(
                points: points,
                legPoint: LegPoint(stop: nil, coordinate: coordinate, name: "")
            )
        }
    }

    // MARK: - Range search

    /// Departure times worth searching from: the moments a rider could actually
    /// board something at one of the access stops.
    ///
    /// Seeding at arbitrary clock times would waste most iterations on instants
    /// where nothing leaves — two searches a minute apart return the same journey
    /// whenever no vehicle departs between them.
    private func candidateDepartures(
        accessPoints: [AccessPoint],
        earliest: ServiceSeconds,
        latest: ServiceSeconds,
        baseDayIndex: Int,
        options: PlanOptions,
        realtime: RealtimeSource,
        limit: Int,
        preferLatest: Bool
    ) -> [ServiceSeconds] {
        guard latest >= earliest else { return [] }
        var times = Set<ServiceSeconds>()
        let usesRealtime = realtime.coveredTripCount > 0
        let lookback: ServiceSeconds = usesRealtime ? 3_600 : 0

        for point in accessPoints {
            guard point.walkMeters <= Int32(options.maximumTotalWalkMeters) else { continue }
            let boardEarliest = earliest + point.walkSeconds
            let boardLatest = latest + point.walkSeconds

            for slot in graph.patternSlots(atStop: point.stop) {
                let pattern = graph.stopPatternReferences[slot]
                guard pattern >= 0, Int(pattern) < graph.patternCount else { continue }
                let position = Int(graph.stopPatternPositions[slot])
                guard graph.patternAllowsBoarding(pattern, at: position) else { continue }
                if options.allowedModes != nil,
                   !options.allows(mode: graph.routeMode(graph.patternRoute(pattern))) {
                    continue
                }

                let tripCount = graph.patternTripCount(pattern)
                guard tripCount > 0 else { continue }

                for dayOffset in -1...1 {
                    let dayIndex = baseDayIndex + dayOffset
                    guard dayIndex >= 0, dayIndex < graph.metadata.calendarDayCount else { continue }
                    let shift = ServiceSeconds(dayOffset) * 86_400
                    let localFrom = boardEarliest - shift
                    let localUntil = boardLatest - shift

                    var offset = firstTripOffset(
                        pattern: pattern,
                        position: position,
                        departingAtOrAfter: localFrom - lookback,
                        tripCount: tripCount
                    )
                    while offset < tripCount {
                        let scheduled = graph.departureTime(
                            pattern: pattern, tripOffset: offset, position: position
                        )
                        if scheduled == noTime { offset += 1; continue }
                        if scheduled > localUntil { break }

                        let trip = graph.globalTripIndex(pattern, offset: offset)
                        guard graph.isServiceActive(graph.tripService(trip), dayIndex: dayIndex) else {
                            offset += 1
                            continue
                        }
                        let adjustment = usesRealtime ? realtime.adjustment(trip: trip, position: position) : nil
                        if adjustment?.blocksBoarding == true { offset += 1; continue }
                        let actual = scheduled + (adjustment?.departureDelay ?? 0)
                        if actual >= localFrom, actual <= localUntil {
                            // The moment the rider must leave the origin to catch
                            // it, which is what the search seeds with.
                            times.insert(actual + shift - point.walkSeconds)
                        }
                        offset += 1
                    }
                }
            }
        }

        guard !times.isEmpty else { return [] }
        var sorted = times.sorted()
        if sorted.count > limit {
            // Keep the end of the window the rider actually asked about: the
            // earliest departures for "leave now", the latest for "arrive by".
            sorted = preferLatest ? Array(sorted.suffix(limit)) : Array(sorted.prefix(limit))
        }
        return sorted
    }

    private func collect(
        builder: JourneyBuilder,
        context: RaptorContext,
        egressPoints: [AccessPoint],
        arrivalDeadline: ServiceSeconds?,
        options: PlanOptions,
        into found: inout [String: Journey]
    ) {
        for round in 1..<context.roundCount {
            for egress in egressPoints {
                guard context.hasLabel(round: round, stop: egress.stop) else { continue }
                guard let journey = builder.journey(round: round, egress: egress) else { continue }
                if let arrivalDeadline, journey.arrival > arrivalDeadline { continue }
                guard journey.walkingMeters <= options.maximumTotalWalkMeters else { continue }
                found[journey.id] = journey
            }
        }
    }

    private func finish(
        found: [String: Journey],
        options: PlanOptions,
        baseDate: ServiceDate,
        statistics: inout PlanStatistics,
        started: Date,
        hitLimit: Bool
    ) -> PlanResult {
        statistics.elapsedSeconds = Date().timeIntervalSince(started)
        statistics.hitTimeLimit = hitLimit

        var journeys = JourneyPlanner.paretoFiltered(Array(found.values))
        journeys.sort { lhs, rhs in
            if lhs.departure != rhs.departure { return lhs.departure < rhs.departure }
            if lhs.arrival != rhs.arrival { return lhs.arrival < rhs.arrival }
            return lhs.transferCount < rhs.transferCount
        }
        if journeys.count > options.maximumResults {
            journeys.removeSubrange(options.maximumResults...)
        }
        return PlanResult(journeys: journeys, baseDate: baseDate, statistics: statistics)
    }

    /// Drops every option that another option beats outright.
    ///
    /// A dominates B when A leaves no earlier, arrives no later and changes no
    /// more often, and is strictly better on at least one of the three. There is
    /// no rider preference under which a dominated option is the right answer, so
    /// showing it only makes the list harder to read.
    static func paretoFiltered(_ journeys: [Journey]) -> [Journey] {
        guard journeys.count > 1 else { return journeys }
        var kept: [Journey] = []
        kept.reserveCapacity(journeys.count)

        for candidate in journeys {
            var dominated = false
            for other in journeys where other.id != candidate.id {
                if dominates(other, candidate) { dominated = true; break }
            }
            if !dominated { kept.append(candidate) }
        }
        // Two journeys can dominate each other only if they are equal on all
        // three criteria, in which case both are dropped above; fall back rather
        // than return nothing.
        return kept.isEmpty ? journeys : kept
    }

    private static func dominates(_ lhs: Journey, _ rhs: Journey) -> Bool {
        let departureNoWorse = lhs.departure >= rhs.departure
        let arrivalNoWorse = lhs.arrival <= rhs.arrival
        let transfersNoWorse = lhs.transferCount <= rhs.transferCount
        guard departureNoWorse, arrivalNoWorse, transfersNoWorse else { return false }
        return lhs.departure > rhs.departure
            || lhs.arrival < rhs.arrival
            || lhs.transferCount < rhs.transferCount
    }

    /// First trip whose scheduled departure at `position` is at or after `time`.
    /// Valid because the importer's overtaking split guarantees trips within a
    /// pattern are ordered by departure at every position, not just the first.
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
            if graph.departureTime(pattern: pattern, tripOffset: middle, position: position) < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

extension PlanStatistics {
    /// Folds one search phase's counters into a running total. A range query runs
    /// several searches and the caller wants the cost of all of them.
    mutating func absorb(_ other: PlanStatistics) {
        rounds = max(rounds, other.rounds)
        patternsScanned += other.patternsScanned
        tripSegmentsScanned += other.tripSegmentsScanned
        stopsImproved += other.stopsImproved
        hitTimeLimit = hitTimeLimit || other.hitTimeLimit
    }
}
