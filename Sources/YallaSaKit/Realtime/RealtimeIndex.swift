import Foundation

/// The GTFS-string-to-graph-index side table, built once per graph.
///
/// Building it walks every trip, stop and route in the graph and materialises a
/// `String` for each id, which for a metro feed is a few hundred thousand
/// allocations and tens of milliseconds. That is fine once and unacceptable every
/// thirty seconds, so **the app keeps one lookup alive for as long as the graph
/// is active** and hands the same instance to every `RealtimeIndex` it builds.
/// Constructing a `RealtimeIndex` without one is supported, but only for tests
/// and one-off tooling.
///
/// Immutable after `init`, hence safe to share across tasks. It is
/// `@unchecked Sendable` for the same reason `TransitGraph` is: it holds one.
public final class RealtimeTripLookup: @unchecked Sendable {
    public let graph: TransitGraph

    private let tripsByIdentifier: [String: TripIndex]
    private let stopsByIdentifier: [String: StopIndex]
    private let routesByIdentifier: [String: RouteIndex]

    /// Reverse of `patternTripStart`/`patternTripCount`. The graph addresses trips
    /// globally for attributes but times only through `(pattern, offset)`, and a
    /// realtime message arrives with neither — so this is the bridge.
    private let patternOfTrip: [PatternIndex]

    public init(graph: TransitGraph) {
        self.graph = graph

        var trips: [String: TripIndex] = [:]
        trips.reserveCapacity(graph.tripCount)
        for index in 0..<graph.tripCount {
            let identifier = graph.tripIdentifier(TripIndex(index))
            if identifier.isEmpty { continue }
            // Feeds do occasionally repeat a trip id. The first wins; picking
            // arbitrarily is better than dropping both, and there is no
            // information available here to pick better.
            if trips[identifier] == nil { trips[identifier] = TripIndex(index) }
        }
        self.tripsByIdentifier = trips

        var stops: [String: StopIndex] = [:]
        stops.reserveCapacity(graph.stopCount)
        for index in 0..<graph.stopCount {
            let identifier = graph.stopIdentifier(StopIndex(index))
            if identifier.isEmpty { continue }
            if stops[identifier] == nil { stops[identifier] = StopIndex(index) }
        }
        self.stopsByIdentifier = stops

        var routes: [String: RouteIndex] = [:]
        routes.reserveCapacity(graph.routeCount)
        for index in 0..<graph.routeCount {
            let identifier = graph.routeIdentifier(RouteIndex(index))
            if identifier.isEmpty { continue }
            if routes[identifier] == nil { routes[identifier] = RouteIndex(index) }
        }
        self.routesByIdentifier = routes

        var patternOfTrip = [PatternIndex](repeating: noIndex, count: graph.tripCount)
        for pattern in 0..<graph.patternCount {
            for trip in graph.tripRange(ofPattern: PatternIndex(pattern)) {
                guard trip >= 0, trip < patternOfTrip.count else { continue }
                patternOfTrip[trip] = PatternIndex(pattern)
            }
        }
        self.patternOfTrip = patternOfTrip
    }

    public func index(forTripID identifier: String) -> TripIndex? {
        tripsByIdentifier[identifier]
    }

    public func index(forStopID identifier: String) -> StopIndex? {
        stopsByIdentifier[identifier]
    }

    public func index(forRouteID identifier: String) -> RouteIndex? {
        routesByIdentifier[identifier]
    }

    /// The pattern a trip belongs to, or `noIndex` if the graph never placed it in
    /// one (which should not happen, but a corrupt graph must not trap here).
    func pattern(ofTrip trip: TripIndex) -> PatternIndex {
        guard trip >= 0, Int(trip) < patternOfTrip.count else { return noIndex }
        return patternOfTrip[Int(trip)]
    }
}

/// One resolved realtime snapshot.
///
/// Every feed string is matched to a graph index exactly once, here, at ingest.
/// After that a query answers from an `Int64`-keyed dictionary and never touches
/// a string, which is what keeps realtime off RAPTOR's critical path: the router
/// asks for an adjustment at every stop of every trip it scans.
public final class RealtimeIndex: RealtimeSource {
    public let generatedAt: Date
    public let alerts: [ServiceAlert]
    /// Trip updates that could not be attached to the graph — an added trip, an
    /// unknown trip id, a trip the import dropped. A number that climbs towards
    /// the feed's whole entity count means the static and realtime feeds have
    /// drifted apart, which is a support question, not a crash.
    public let unmatchedTripCount: Int
    public let coveredTripCount: Int

    /// `(tripIndex, position)` packed into one `Int64`. A dictionary keyed on a
    /// tuple or a struct would hash two fields and allocate nothing but would
    /// still cost more per probe than shifting two integers together, and this is
    /// looked up once per (trip, stop) pair the router examines.
    private let adjustments: [Int64: RealtimeAdjustment]
    private let cancelledTrips: Set<TripIndex>

    public init(
        feed: GTFSRealtimeFeed,
        graph: TransitGraph,
        referenceDate: ServiceDate,
        lookup: RealtimeTripLookup? = nil
    ) {
        let resolver = lookup ?? RealtimeTripLookup(graph: graph)

        var builder = SnapshotBuilder(graph: graph, lookup: resolver, referenceDate: referenceDate)
        builder.reserve(forUpdateCount: feed.tripUpdates.count)
        for update in feed.tripUpdates {
            builder.ingest(update)
        }

        self.generatedAt = feed.generatedAt
        self.adjustments = builder.adjustments
        self.cancelledTrips = builder.cancelledTrips
        self.coveredTripCount = builder.coveredTrips.count
        self.unmatchedTripCount = builder.unmatchedTripCount

        var resolvedAlerts: [ServiceAlert] = []
        resolvedAlerts.reserveCapacity(feed.alerts.count)
        for (offset, alert) in feed.alerts.enumerated() {
            if let resolved = RealtimeIndex.serviceAlert(from: alert, ordinal: offset, lookup: resolver) {
                resolvedAlerts.append(resolved)
            }
        }
        self.alerts = resolvedAlerts
    }

    // MARK: - RealtimeSource

    public func adjustment(trip: TripIndex, position: Int) -> RealtimeAdjustment? {
        adjustments[RealtimeIndex.key(trip: trip, position: position)]
    }

    public func isCancelled(trip: TripIndex) -> Bool {
        cancelledTrips.contains(trip)
    }

    @inline(__always)
    static func key(trip: TripIndex, position: Int) -> Int64 {
        (Int64(trip) << 32) | Int64(UInt32(truncatingIfNeeded: position))
    }

    // MARK: - Alerts

    private static func serviceAlert(
        from alert: RTAlert,
        ordinal: Int,
        lookup: RealtimeTripLookup
    ) -> ServiceAlert? {
        let header = alert.headerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = alert.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        // An alert with no text has nothing to show a rider, and the engine does
        // not route around alerts, so it would be invisible work.
        guard !header.isEmpty || !body.isEmpty else { return nil }

        var routes: Set<RouteIndex> = []
        var stops: Set<StopIndex> = []
        var trips: Set<TripIndex> = []
        for selector in alert.informedEntities {
            if let routeID = selector.routeID, !routeID.isEmpty,
               let route = lookup.index(forRouteID: routeID) {
                routes.insert(route)
            }
            if let stopID = selector.stopID, !stopID.isEmpty,
               let stop = lookup.index(forStopID: stopID) {
                stops.insert(stop)
            }
            if let tripID = selector.trip?.tripID, !tripID.isEmpty,
               let trip = lookup.index(forTripID: tripID) {
                trips.insert(trip)
            }
            // `agency_id` and `route_type` select whole classes of service. They
            // are left unexpanded: turning "all ferries" into a set of thousands
            // of indices would cost more than the UI saves by having it, and the
            // alert still shows in the network-wide list.
        }

        var activeFrom: Date?
        var activeUntil: Date?
        var openStart = alert.activePeriods.isEmpty
        var openEnd = alert.activePeriods.isEmpty
        for period in alert.activePeriods {
            if let start = period.start, start > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(start))
                activeFrom = activeFrom.map { Swift.min($0, date) } ?? date
            } else {
                openStart = true
            }
            if let end = period.end, end > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(end))
                activeUntil = activeUntil.map { Swift.max($0, date) } ?? date
            } else {
                openEnd = true
            }
        }

        let effect = alert.effect ?? .unknownEffect
        return ServiceAlert(
            id: alert.entityID.isEmpty ? "alert-\(ordinal)" : alert.entityID,
            headerText: header.isEmpty ? body : header,
            descriptionText: body,
            url: alert.url,
            effect: effect.serviceAlertEffect,
            severity: alert.severityLevel?.serviceAlertSeverity ?? inferredSeverity(for: effect),
            activeFrom: openStart ? nil : activeFrom,
            activeUntil: openEnd ? nil : activeUntil,
            routes: routes,
            stops: stops,
            trips: trips
        )
    }

    /// `severity_level` was added late to the spec and most producers still omit
    /// it, so the effect — which everyone sets — stands in for it.
    private static func inferredSeverity(for effect: RTAlertEffect) -> ServiceAlert.Severity {
        switch effect {
        case .noService:
            return .severe
        case .reducedService, .significantDelays, .detour, .stopMoved:
            return .warning
        case .additionalService, .modifiedService, .accessibilityIssue, .otherEffect, .noEffect:
            return .info
        case .unknownEffect:
            return .unknown
        }
    }
}

// MARK: - Ingest

/// Resolves trip updates into the flat adjustment table.
///
/// A struct rather than free functions so the midnight cache and the scratch
/// arrays survive across updates; a big feed carries several thousand of them and
/// `Calendar` is far too slow to ask for midnight once per trip.
private struct SnapshotBuilder {
    let graph: TransitGraph
    let lookup: RealtimeTripLookup
    let referenceDate: ServiceDate

    var adjustments: [Int64: RealtimeAdjustment] = [:]
    var cancelledTrips: Set<TripIndex> = []
    var coveredTrips: Set<TripIndex> = []
    var unmatchedTripCount = 0

    private var midnightCache: [ServiceDate: Int64] = [:]

    /// A delay of more than a day is a producer bug — a stale prediction, a
    /// timezone mistake, an uninitialised field — not a bus. Clamping keeps one
    /// bad entity from rendering a departure board as nonsense, and keeps the
    /// arithmetic inside `Int32` no matter what arrives.
    private static let delayLimit: Int64 = 86_400

    init(graph: TransitGraph, lookup: RealtimeTripLookup, referenceDate: ServiceDate) {
        self.graph = graph
        self.lookup = lookup
        self.referenceDate = referenceDate
    }

    mutating func reserve(forUpdateCount count: Int) {
        // Most updates touch a handful of stops; over-reserving a snapshot that is
        // discarded in thirty seconds is cheaper than rehashing it twice.
        adjustments.reserveCapacity(count * 8)
        coveredTrips.reserveCapacity(count)
    }

    mutating func ingest(_ update: RTTripUpdate) {
        let relationship = update.trip.effectiveScheduleRelationship

        // ADDED / UNSCHEDULED / DUPLICATED trips describe vehicles the static
        // graph has no row for. There is no index to hang them off, so they are
        // counted and dropped rather than silently ignored.
        if relationship.isUnrepresentableInStaticSchedule {
            unmatchedTripCount += 1
            return
        }

        guard let tripID = update.trip.tripID, !tripID.isEmpty,
              let trip = lookup.index(forTripID: tripID) else {
            unmatchedTripCount += 1
            return
        }

        let pattern = lookup.pattern(ofTrip: trip)
        guard pattern != noIndex else {
            unmatchedTripCount += 1
            return
        }
        let stopCount = graph.patternStopCount(pattern)
        guard stopCount > 0 else {
            unmatchedTripCount += 1
            return
        }

        if relationship.removesTrip {
            cancelledTrips.insert(trip)
            coveredTrips.insert(trip)
            // Written at every position as well as into the cancelled set: the
            // router's fast path asks `isCancelled(trip:)`, but a departure board
            // asks for one stop and must not see "no data" for a cancelled trip.
            for position in 0..<stopCount {
                adjustments[RealtimeIndex.key(trip: trip, position: position)] =
                    RealtimeAdjustment(isCancelled: true)
            }
            return
        }

        let tripRange = graph.tripRange(ofPattern: pattern)
        let tripOffset = Int(trip) - tripRange.lowerBound
        guard tripOffset >= 0, tripOffset < tripRange.count else {
            unmatchedTripCount += 1
            return
        }

        let serviceDate = update.trip.startDate ?? referenceDate
        let offset = Self.sequenceOffset(for: update, stopCount: stopCount)

        var explicitArrival = [Int32?](repeating: nil, count: stopCount)
        var explicitDeparture = [Int32?](repeating: nil, count: stopCount)
        var isSkipped = [Bool](repeating: false, count: stopCount)
        var hasNoData = [Bool](repeating: false, count: stopCount)
        var sawAnything = false

        for stopTimeUpdate in update.stopTimeUpdates {
            guard let position = resolvePosition(
                of: stopTimeUpdate,
                pattern: pattern,
                stopCount: stopCount,
                sequenceOffset: offset
            ) else { continue }

            switch stopTimeUpdate.scheduleRelationship {
            case .skipped:
                isSkipped[position] = true
                sawAnything = true
                continue
            case .noData:
                hasNoData[position] = true
                sawAnything = true
                continue
            case .scheduled, .unscheduled:
                break
            }

            let scheduledArrival = graph.arrivalTime(
                pattern: pattern, tripOffset: tripOffset, position: position
            )
            let scheduledDeparture = graph.departureTime(
                pattern: pattern, tripOffset: tripOffset, position: position
            )
            let arrival = resolvedDelay(
                from: stopTimeUpdate.arrival, scheduled: scheduledArrival, serviceDate: serviceDate
            )
            let departure = resolvedDelay(
                from: stopTimeUpdate.departure, scheduled: scheduledDeparture, serviceDate: serviceDate
            )
            if arrival != nil || departure != nil {
                explicitArrival[position] = arrival
                explicitDeparture[position] = departure
                sawAnything = true
            }
        }

        // The trip-level delay is the spec's answer for "everything else on this
        // trip", so it seeds the propagation rather than competing with it.
        var carriedArrival: Int32? = update.delay
        var carriedDeparture: Int32? = update.delay
        if update.delay != nil { sawAnything = true }

        var wroteAnything = false
        for position in 0..<stopCount {
            if hasNoData[position] {
                // NO_DATA means "we know nothing here", which is not the same as
                // "the last delay still holds": the prediction stops, and so does
                // the propagation.
                carriedArrival = nil
                carriedDeparture = nil
                continue
            }

            var arrival = explicitArrival[position]
            var departure = explicitDeparture[position]
            // A producer that gives only one side of a stop means the same thing
            // for both; every reference implementation mirrors it, and leaving the
            // other side at zero would show a rider a bus that arrives late and
            // departs on time.
            if arrival == nil, departure != nil { arrival = departure }
            if departure == nil, arrival != nil { departure = arrival }

            if arrival != nil || departure != nil {
                carriedArrival = arrival
                carriedDeparture = departure
            } else {
                arrival = carriedArrival
                departure = carriedDeparture
            }

            if isSkipped[position] {
                adjustments[RealtimeIndex.key(trip: trip, position: position)] = RealtimeAdjustment(
                    arrivalDelay: arrival ?? 0,
                    departureDelay: departure ?? 0,
                    isCancelled: false,
                    isSkipped: true
                )
                wroteAnything = true
            } else if arrival != nil || departure != nil {
                adjustments[RealtimeIndex.key(trip: trip, position: position)] = RealtimeAdjustment(
                    arrivalDelay: arrival ?? 0,
                    departureDelay: departure ?? 0
                )
                wroteAnything = true
            }
        }

        if wroteAnything || sawAnything {
            coveredTrips.insert(trip)
        }
    }

    // MARK: Position resolution

    /// Maps a `StopTimeUpdate` onto a 0-based position along the trip's pattern.
    ///
    /// **The limitation.** `stop_sequence` is the GTFS `stop_times.stop_sequence`
    /// value, which is only required to increase along the trip — `1, 2, 3…`,
    /// `0, 1, 2…` and `10, 20, 30…` are all conforming. The compiled graph does
    /// not keep those numbers (a pattern is defined by its stop list, and the
    /// numbers vary between trips that share one), so there is nothing here to
    /// match them against.
    ///
    /// So: resolve by `stop_id` whenever the producer supplies one, which is the
    /// overwhelming majority of real messages, and fall back to reading
    /// `stop_sequence` as an ordinal otherwise. The fallback is exact for
    /// 0-based feeds and, thanks to `sequenceOffset`, for 1-based feeds whose
    /// updates reach the last stop. It is off by one for a 1-based feed that
    /// sends no `stop_id` and no update for the final stop, and wrong for a feed
    /// that numbers in tens. Those feeds exist; preserving `stop_sequence`
    /// through the importer is the real fix and needs a graph format change.
    private func resolvePosition(
        of update: RTStopTimeUpdate,
        pattern: PatternIndex,
        stopCount: Int,
        sequenceOffset: Int
    ) -> Int? {
        if let stopID = update.stopID, !stopID.isEmpty,
           let stop = lookup.index(forStopID: stopID) {
            let preferred: Int? = update.stopSequence.map { Int($0) - sequenceOffset }
            var firstMatch: Int?
            for candidate in 0..<stopCount where graph.patternStop(pattern, at: candidate) == stop {
                if firstMatch == nil { firstMatch = candidate }
                // A loop route visits the same stop twice; the sequence number
                // disambiguates even when it cannot locate on its own.
                if let preferred, preferred == candidate { return candidate }
            }
            if let firstMatch { return firstMatch }
        }

        guard let sequence = update.stopSequence else { return nil }
        let ordinal = Int(sequence) - sequenceOffset
        guard ordinal >= 0, ordinal < stopCount else { return nil }
        return ordinal
    }

    /// Returns 1 when this trip update's `stop_sequence` values can only be
    /// 1-based — they never hit zero and one of them is exactly `stopCount`,
    /// which a 0-based numbering could never produce.
    private static func sequenceOffset(for update: RTTripUpdate, stopCount: Int) -> Int {
        var sawZero = false
        var maximum = 0
        var sawAny = false
        for stopTimeUpdate in update.stopTimeUpdates {
            guard let sequence = stopTimeUpdate.stopSequence else { continue }
            sawAny = true
            if sequence == 0 { sawZero = true }
            if Int(sequence) > maximum { maximum = Int(sequence) }
        }
        guard sawAny, !sawZero, maximum == stopCount else { return 0 }
        return 1
    }

    // MARK: Delays

    private mutating func resolvedDelay(
        from event: RTStopTimeEvent?,
        scheduled: ServiceSeconds,
        serviceDate: ServiceDate
    ) -> Int32? {
        guard let event else { return nil }
        // `delay` is preferred over `time` when both are present: it is already
        // relative to the schedule and so cannot be thrown off by our idea of
        // which service day the trip belongs to.
        if let delay = event.delay { return Self.clamped(Int64(delay)) }
        guard let time = event.time, time > 0, scheduled != noTime else { return nil }
        guard let midnight = midnightEpoch(for: serviceDate) else { return nil }
        return Self.clamped(time - (midnight + Int64(scheduled)))
    }

    /// Midnight of a service day as POSIX seconds, in the graph's timezone.
    ///
    /// Cached because `Calendar.date(from:)` costs microseconds and this is asked
    /// once per stop-time event in a feed that can carry a hundred thousand.
    private mutating func midnightEpoch(for date: ServiceDate) -> Int64? {
        if let cached = midnightCache[date] { return cached }
        guard let midnight = date.startOfDay(in: graph.timeZone) else { return nil }
        let seconds = Int64(midnight.timeIntervalSince1970.rounded())
        midnightCache[date] = seconds
        return seconds
    }

    private static func clamped(_ seconds: Int64) -> Int32 {
        if seconds > delayLimit { return Int32(delayLimit) }
        if seconds < -delayLimit { return Int32(-delayLimit) }
        return Int32(seconds)
    }
}
