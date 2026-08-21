import Foundation

/// A realtime deviation from the timetable for one trip at one stop.
public struct RealtimeAdjustment: Hashable, Sendable {
    /// Seconds late; negative means running early.
    public var arrivalDelay: Int32
    public var departureDelay: Int32
    /// The whole trip is cancelled.
    public var isCancelled: Bool
    /// The vehicle runs but skips this particular stop.
    public var isSkipped: Bool

    public init(arrivalDelay: Int32 = 0, departureDelay: Int32 = 0, isCancelled: Bool = false, isSkipped: Bool = false) {
        self.arrivalDelay = arrivalDelay
        self.departureDelay = departureDelay
        self.isCancelled = isCancelled
        self.isSkipped = isSkipped
    }

    /// True when the router must not use this trip at this stop at all.
    public var blocksBoarding: Bool { isCancelled || isSkipped }

    public static let none = RealtimeAdjustment()
}

/// Supplies realtime deviations to the router and the departure boards.
///
/// Lookups are by `TripIndex`, not by GTFS trip id: matching feed strings to
/// graph indices happens once when a snapshot is ingested, so the router's inner
/// loop never touches a string or a hash of one. Implementations must be safe to
/// call from several threads at once and must not block — a query holds a
/// reference to one immutable snapshot for its whole duration.
public protocol RealtimeSource: AnyObject, Sendable {
    /// When the underlying feed was generated. Drives the "updated 20s ago" label
    /// and lets the app decide a snapshot is too stale to trust.
    var generatedAt: Date { get }

    /// Deviation for `trip` at `position` along its pattern, or `nil` when this
    /// trip is not covered — which is different from "covered and on time".
    func adjustment(trip: TripIndex, position: Int) -> RealtimeAdjustment?

    /// Fast pre-check so the router can skip a trip without a per-stop lookup.
    func isCancelled(trip: TripIndex) -> Bool

    /// Number of trips this snapshot has data for, for diagnostics.
    var coveredTripCount: Int { get }
}

public extension RealtimeSource {
    /// Applies the snapshot to a scheduled departure time.
    func adjustedDeparture(
        trip: TripIndex,
        position: Int,
        scheduled: ServiceSeconds
    ) -> (time: ServiceSeconds, delay: Int32?, blocked: Bool) {
        guard let adjustment = adjustment(trip: trip, position: position) else {
            return (scheduled, nil, false)
        }
        if adjustment.blocksBoarding { return (scheduled, adjustment.departureDelay, true) }
        return (scheduled + adjustment.departureDelay, adjustment.departureDelay, false)
    }

    func adjustedArrival(
        trip: TripIndex,
        position: Int,
        scheduled: ServiceSeconds
    ) -> (time: ServiceSeconds, delay: Int32?) {
        guard let adjustment = adjustment(trip: trip, position: position), !adjustment.isCancelled else {
            return (scheduled, nil)
        }
        return (scheduled + adjustment.arrivalDelay, adjustment.arrivalDelay)
    }
}

/// The no-realtime case. Used offline, when the feed has no realtime endpoint,
/// and when the rider turns realtime off.
public final class EmptyRealtimeSource: RealtimeSource {
    public static let shared = EmptyRealtimeSource()
    public init() {}

    public var generatedAt: Date { .distantPast }
    public func adjustment(trip: TripIndex, position: Int) -> RealtimeAdjustment? { nil }
    public func isCancelled(trip: TripIndex) -> Bool { false }
    public var coveredTripCount: Int { 0 }
}

/// A service alert affecting a route, stop or trip. Alerts do not change routing
/// results; they annotate them, so they live outside `RealtimeSource`.
public struct ServiceAlert: Hashable, Sendable, Identifiable {
    public enum Effect: String, Hashable, Sendable, Codable {
        case noService, reducedService, significantDelays, detour, additionalService
        case modifiedService, otherEffect, unknownEffect, stopMoved, noEffect, accessibilityIssue
    }

    public enum Severity: Int, Hashable, Sendable, Codable, Comparable {
        case unknown = 0, info = 1, warning = 2, severe = 3
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var headerText: String
    public var descriptionText: String
    public var url: String?
    public var effect: Effect
    public var severity: Severity
    public var activeFrom: Date?
    public var activeUntil: Date?
    /// Graph indices the alert applies to, resolved at ingest time.
    public var routes: Set<RouteIndex>
    public var stops: Set<StopIndex>
    public var trips: Set<TripIndex>

    public init(
        id: String, headerText: String, descriptionText: String, url: String?,
        effect: Effect, severity: Severity, activeFrom: Date?, activeUntil: Date?,
        routes: Set<RouteIndex>, stops: Set<StopIndex>, trips: Set<TripIndex>
    ) {
        self.id = id
        self.headerText = headerText
        self.descriptionText = descriptionText
        self.url = url
        self.effect = effect
        self.severity = severity
        self.activeFrom = activeFrom
        self.activeUntil = activeUntil
        self.routes = routes
        self.stops = stops
        self.trips = trips
    }

    public func isActive(at date: Date) -> Bool {
        if let activeFrom, date < activeFrom { return false }
        if let activeUntil, date > activeUntil { return false }
        return true
    }
}
