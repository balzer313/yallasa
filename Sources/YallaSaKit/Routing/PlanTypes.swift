import Foundation

// MARK: - Request

/// Where a journey starts or ends.
public enum PlanEndpoint: Hashable, Sendable {
    /// An exact stop. Used when the rider taps a stop on the map or a departure.
    case stop(StopIndex)
    /// A free coordinate. The router finds its own access/egress stops.
    case coordinate(GeoPoint)

    public var coordinateValue: GeoPoint? {
        if case .coordinate(let point) = self { return point }
        return nil
    }
}

/// Whether the given time is a "leave after" or a "be there by" constraint.
public enum PlanTimeAnchor: Hashable, Sendable {
    case departAfter(ServiceInstant)
    case arriveBy(ServiceInstant)

    public var instant: ServiceInstant {
        switch self {
        case .departAfter(let value), .arriveBy(let value): return value
        }
    }

    public var isArriveBy: Bool {
        if case .arriveBy = self { return true }
        return false
    }
}

/// Everything a rider can tune about a search. Defaults are tuned for a typical
/// urban bus trip; the UI exposes walking distance, transfer count, modes and
/// accessibility.
public struct PlanOptions: Hashable, Sendable, Codable {
    /// RAPTOR rounds minus one. Four transfers covers essentially every real
    /// urban journey; raising it costs a full extra round of pattern scanning.
    public var maximumTransfers: Int = 4

    public var walkingSpeedMetersPerSecond: Double = 1.33
    /// Multiplier applied to straight-line distance to approximate street
    /// walking. 1.35 is the median detour ratio observed in gridded cities.
    public var walkingDetourFactor: Double = 1.35

    public var maximumAccessWalkMeters: Double = 1000
    public var maximumEgressWalkMeters: Double = 1000
    public var maximumTotalWalkMeters: Double = 3000
    /// Slack demanded on top of a footpath before a connection counts as made.
    public var minimumTransferSeconds: Int = 45

    public var requiresWheelchairAccess = false
    public var allowsBicycles = false
    /// `nil` means every mode in the feed.
    public var allowedModes: Set<TransitMode>?

    /// How far past the anchor time range-RAPTOR keeps looking for later, better
    /// departures. One hour gives a Moovit-like "and the next three after that".
    public var searchWindowSeconds: Int = 3600
    public var maximumResults: Int = 6

    public var usesRealtime = true

    /// Hard ceiling on router wall-clock. A pathological feed should degrade to
    /// "here is what I found in 2 seconds", never to a spinning UI.
    public var timeLimitSeconds: Double = 2.0

    public init() {}

    public func walkingSeconds(forMeters meters: Double) -> Int32 {
        Int32((meters * walkingDetourFactor / max(walkingSpeedMetersPerSecond, 0.1)).rounded(.up))
    }

    public func allows(mode: TransitMode) -> Bool {
        guard let allowedModes else { return true }
        return allowedModes.contains(mode)
    }
}

public struct PlanRequest: Hashable, Sendable {
    public var origin: PlanEndpoint
    public var destination: PlanEndpoint
    public var anchor: PlanTimeAnchor
    public var options: PlanOptions

    public init(
        origin: PlanEndpoint,
        destination: PlanEndpoint,
        anchor: PlanTimeAnchor,
        options: PlanOptions = PlanOptions()
    ) {
        self.origin = origin
        self.destination = destination
        self.anchor = anchor
        self.options = options
    }
}

// MARK: - Result

/// A point at either end of a leg.
public struct LegPoint: Hashable, Sendable {
    /// `nil` when the point is the rider's own location rather than a stop.
    public var stop: StopIndex?
    public var coordinate: GeoPoint
    public var name: String

    public init(stop: StopIndex?, coordinate: GeoPoint, name: String) {
        self.stop = stop
        self.coordinate = coordinate
        self.name = name
    }
}

/// A leg on foot: to the first stop, between two stops, or from the last stop.
public struct WalkLeg: Hashable, Sendable {
    public var origin: LegPoint
    public var destination: LegPoint
    /// Seconds from midnight of the journey's `baseDate`. May exceed 86400.
    public var departure: ServiceSeconds
    public var arrival: ServiceSeconds
    public var distanceMeters: Double

    public var durationSeconds: Int32 { arrival - departure }

    public init(
        origin: LegPoint, destination: LegPoint,
        departure: ServiceSeconds, arrival: ServiceSeconds,
        distanceMeters: Double
    ) {
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.arrival = arrival
        self.distanceMeters = distanceMeters
    }
}

/// A leg aboard a vehicle.
public struct RideLeg: Hashable, Sendable {
    public var pattern: PatternIndex
    /// Position of the trip within its pattern, which is how times are addressed.
    public var tripOffset: Int
    public var trip: TripIndex
    public var route: RouteIndex

    public var boardPosition: Int
    public var alightPosition: Int
    public var boardStop: StopIndex
    public var alightStop: StopIndex

    /// Timetable times, in the journey's `baseDate` frame.
    public var scheduledDeparture: ServiceSeconds
    public var scheduledArrival: ServiceSeconds
    /// Realtime deviation in seconds, positive for late. `nil` when no realtime
    /// data covers this trip — which the UI must show differently from "on time".
    public var departureDelay: Int32?
    public var arrivalDelay: Int32?

    /// The service day the trip belongs to, which is not always the journey's
    /// base date — a 00:20 departure is usually yesterday's service.
    public var serviceDate: ServiceDate

    public var stopCount: Int { alightPosition - boardPosition }

    public var actualDeparture: ServiceSeconds { scheduledDeparture + (departureDelay ?? 0) }
    public var actualArrival: ServiceSeconds { scheduledArrival + (arrivalDelay ?? 0) }

    public init(
        pattern: PatternIndex, tripOffset: Int, trip: TripIndex, route: RouteIndex,
        boardPosition: Int, alightPosition: Int, boardStop: StopIndex, alightStop: StopIndex,
        scheduledDeparture: ServiceSeconds, scheduledArrival: ServiceSeconds,
        departureDelay: Int32?, arrivalDelay: Int32?, serviceDate: ServiceDate
    ) {
        self.pattern = pattern
        self.tripOffset = tripOffset
        self.trip = trip
        self.route = route
        self.boardPosition = boardPosition
        self.alightPosition = alightPosition
        self.boardStop = boardStop
        self.alightStop = alightStop
        self.scheduledDeparture = scheduledDeparture
        self.scheduledArrival = scheduledArrival
        self.departureDelay = departureDelay
        self.arrivalDelay = arrivalDelay
        self.serviceDate = serviceDate
    }
}

public enum JourneyLeg: Hashable, Sendable {
    case walk(WalkLeg)
    case ride(RideLeg)

    public var departure: ServiceSeconds {
        switch self {
        case .walk(let leg): return leg.departure
        case .ride(let leg): return leg.actualDeparture
        }
    }

    public var arrival: ServiceSeconds {
        switch self {
        case .walk(let leg): return leg.arrival
        case .ride(let leg): return leg.actualArrival
        }
    }

    public var rideLeg: RideLeg? {
        if case .ride(let leg) = self { return leg }
        return nil
    }

    public var walkLeg: WalkLeg? {
        if case .walk(let leg) = self { return leg }
        return nil
    }
}

/// One complete door-to-door option.
///
/// All times are seconds from midnight of `baseDate` in the feed's timezone, and
/// may exceed 86400 for journeys that cross midnight. Converting to a wall-clock
/// `Date` happens at the display boundary, never inside the engine.
public struct Journey: Hashable, Sendable, Identifiable {
    public var legs: [JourneyLeg]
    public var baseDate: ServiceDate

    public init(legs: [JourneyLeg], baseDate: ServiceDate) {
        self.legs = legs
        self.baseDate = baseDate
    }

    public var id: String {
        // Stable across recomputation of the same option, so SwiftUI keeps row
        // identity when realtime updates refresh the result set.
        var parts: [String] = ["\(baseDate.gtfsString)"]
        for leg in legs {
            switch leg {
            case .ride(let ride):
                parts.append("r\(ride.trip)-\(ride.boardPosition)-\(ride.alightPosition)")
            case .walk(let walk):
                parts.append("w\(walk.origin.stop ?? -1)-\(walk.destination.stop ?? -1)")
            }
        }
        return parts.joined(separator: "|")
    }

    public var departure: ServiceSeconds { legs.first?.departure ?? 0 }
    public var arrival: ServiceSeconds { legs.last?.arrival ?? 0 }
    public var durationSeconds: Int32 { arrival - departure }

    /// The first moment the rider must be moving. For a journey that starts with
    /// a walk this is the walk's start, which is what a countdown should show.
    public var departureInstant: ServiceInstant {
        ServiceInstant(date: baseDate, seconds: departure).normalised
    }

    public var arrivalInstant: ServiceInstant {
        ServiceInstant(date: baseDate, seconds: arrival).normalised
    }

    public var rides: [RideLeg] { legs.compactMap(\.rideLeg) }
    public var transferCount: Int { max(0, rides.count - 1) }
    public var walkingMeters: Double { legs.compactMap(\.walkLeg).reduce(0) { $0 + $1.distanceMeters } }
    public var walkingSeconds: Int32 { legs.compactMap(\.walkLeg).reduce(0) { $0 + $1.durationSeconds } }

    /// True when the whole journey is on foot — the router returns one of these
    /// when walking beats waiting, and the UI should say so rather than hide it.
    public var isWalkOnly: Bool { rides.isEmpty }

    public var usesRealtime: Bool {
        rides.contains { $0.departureDelay != nil || $0.arrivalDelay != nil }
    }
}

/// What the search did, for the performance HUD and for tests that assert the
/// router is not quietly doing 10x the work it should.
public struct PlanStatistics: Hashable, Sendable {
    public var rounds = 0
    public var patternsScanned = 0
    public var tripSegmentsScanned = 0
    public var stopsImproved = 0
    public var departuresProbed = 0
    public var elapsedSeconds: Double = 0
    public var hitTimeLimit = false

    public init() {}
}

public struct PlanResult: Sendable {
    public var journeys: [Journey]
    public var baseDate: ServiceDate
    public var statistics: PlanStatistics

    public init(journeys: [Journey], baseDate: ServiceDate, statistics: PlanStatistics) {
        self.journeys = journeys
        self.baseDate = baseDate
        self.statistics = statistics
    }

    public var isEmpty: Bool { journeys.isEmpty }
}

public enum PlanError: Error, LocalizedError, Equatable {
    /// The rider is outside the feed's coverage, or too far from any stop.
    case noStopsNearOrigin
    case noStopsNearDestination
    /// The feed's calendar does not include the requested date.
    case dateNotCovered(ServiceDate)
    /// Origin and destination resolve to the same stop.
    case trivialJourney
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noStopsNearOrigin:
            return "There are no stops within walking distance of the starting point."
        case .noStopsNearDestination:
            return "There are no stops within walking distance of the destination."
        case .dateNotCovered(let date):
            return "The timetable does not cover \(date.gtfsString). Refresh the feed to get newer data."
        case .trivialJourney:
            return "The start and the destination are the same place."
        case .cancelled:
            return "The search was cancelled."
        }
    }
}

// MARK: - Departure boards

/// One upcoming departure from a stop. This is what the nearby board and a
/// stop's detail screen are made of; it is deliberately not a `Journey`, because
/// it needs to be cheap enough to recompute every second for a live countdown.
public struct Departure: Hashable, Sendable, Identifiable {
    public var stop: StopIndex
    public var pattern: PatternIndex
    public var tripOffset: Int
    public var trip: TripIndex
    public var route: RouteIndex
    public var position: Int

    /// Seconds from midnight of `queryDate`; may exceed 86400.
    public var scheduledDeparture: ServiceSeconds
    public var delay: Int32?
    public var isCancelled: Bool
    public var serviceDate: ServiceDate
    public var queryDate: ServiceDate

    public init(
        stop: StopIndex, pattern: PatternIndex, tripOffset: Int, trip: TripIndex,
        route: RouteIndex, position: Int, scheduledDeparture: ServiceSeconds,
        delay: Int32?, isCancelled: Bool, serviceDate: ServiceDate, queryDate: ServiceDate
    ) {
        self.stop = stop
        self.pattern = pattern
        self.tripOffset = tripOffset
        self.trip = trip
        self.route = route
        self.position = position
        self.scheduledDeparture = scheduledDeparture
        self.delay = delay
        self.isCancelled = isCancelled
        self.serviceDate = serviceDate
        self.queryDate = queryDate
    }

    public var id: String { "\(trip)-\(stop)-\(position)-\(serviceDate.gtfsString)" }

    public var actualDeparture: ServiceSeconds { scheduledDeparture + (delay ?? 0) }

    public var instant: ServiceInstant {
        ServiceInstant(date: queryDate, seconds: actualDeparture).normalised
    }

    /// Seconds until departure relative to `now` in the same day frame.
    public func countdown(from now: ServiceSeconds) -> Int32 { actualDeparture - now }
}
