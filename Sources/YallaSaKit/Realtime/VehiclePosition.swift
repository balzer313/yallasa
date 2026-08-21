import Foundation

/// Where one vehicle actually is, right now.
///
/// This is a different kind of fact from `RealtimeAdjustment`. An adjustment says
/// "trip 41 is 90 seconds late at stop 12" — it is a correction to the timetable,
/// and the router consumes it. A `VehiclePosition` is a GPS fix: a dot on a map
/// with a heading. Nothing in the router uses it, and it deliberately carries no
/// `TripIndex`, because the feeds that publish positions frequently cannot say
/// which scheduled trip a vehicle is running.
public struct VehiclePosition: Hashable, Sendable, Identifiable {
    /// Stable for as long as the vehicle keeps reporting, so the map can animate
    /// a marker from one fix to the next instead of making it blink.
    public var id: String
    public var point: GeoPoint
    /// Compass degrees, 0 = north, clockwise. Absent when the feed does not say,
    /// which is common for a stationary vehicle.
    public var bearingDegrees: Double?
    public var speedKilometresPerHour: Double?
    /// When the vehicle reported this fix — *not* when we fetched it. The gap
    /// between the two is what the UI must show, because a 4-minute-old dot
    /// drawn as if it were current is worse than no dot.
    public var recordedAt: Date
    /// The operator's identifier for the line. In Israel's MOT data this is the
    /// SIRI `LineRef`, which is also the GTFS `route_id` — so it maps straight
    /// onto `TransitGraph.routeIdentifier(_:)` with no translation table.
    public var lineReference: String
    public var operatorReference: String?
    /// Identifies the specific run, where the feed provides it.
    public var journeyReference: String?

    public init(
        id: String,
        point: GeoPoint,
        bearingDegrees: Double? = nil,
        speedKilometresPerHour: Double? = nil,
        recordedAt: Date,
        lineReference: String,
        operatorReference: String? = nil,
        journeyReference: String? = nil
    ) {
        self.id = id
        self.point = point
        self.bearingDegrees = bearingDegrees
        self.speedKilometresPerHour = speedKilometresPerHour
        self.recordedAt = recordedAt
        self.lineReference = lineReference
        self.operatorReference = operatorReference
        self.journeyReference = journeyReference
    }

    /// How stale this fix is. The caller decides what is too old; a source that
    /// polls every 30 s and a source that publishes every 5 minutes have very
    /// different ideas of "current".
    public func age(at now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(recordedAt)
    }

    /// True when the vehicle is reporting movement. Used to decide whether to
    /// draw a heading arrow at all — a parked bus with a stale bearing pointing
    /// down a road it is not on reads as a bug.
    public var isMoving: Bool {
        (speedKilometresPerHour ?? 0) > 1
    }
}

/// Supplies live vehicle positions for a region.
///
/// Separate from `RealtimeSource` on purpose. `RealtimeSource` is a snapshot
/// ingested once and then queried synchronously by index from the router's inner
/// loop; this is an async, region-scoped fetch driven by what the map is showing.
/// Conflating them would drag networking into the routing path.
public protocol VehiclePositionSource: Sendable {
    /// Positions inside `bounds` reported within `window` of now.
    ///
    /// Implementations return at most one position per vehicle — the freshest —
    /// and must not throw for an empty result: no buses running is a normal
    /// answer at 03:00, and on Shabbat it is the answer across most of Israel.
    func vehicles(
        in bounds: GeoBounds,
        within window: TimeInterval,
        limit: Int
    ) async throws -> [VehiclePosition]
}

/// Which keyless live-position service a feed can use.
///
/// An enum rather than a URL because these are not interchangeable endpoints:
/// each speaks its own shape and needs its own client. A feed says *which*
/// service covers it and the app picks the matching implementation.
public enum VehiclePositionService: String, Codable, Hashable, Sendable, CaseIterable {
    /// Open Bus / Stride, run by the Public Knowledge Workshop. Covers Israel,
    /// needs no key. See `StrideVehicleSource`.
    case openBusStride

    public var attribution: String {
        switch self {
        case .openBusStride: return StrideVehicleSource.attribution
        }
    }

    /// How often the underlying feed is worth re-asking. Israeli SIRI updates
    /// roughly once a minute, so polling faster spends battery to redraw the
    /// same dots.
    public var refreshInterval: TimeInterval {
        switch self {
        case .openBusStride: return 20
        }
    }

    public func makeSource() -> VehiclePositionSource {
        switch self {
        case .openBusStride: return StrideVehicleSource()
        }
    }
}

public enum VehiclePositionError: Error, LocalizedError, Equatable {
    case transport(String)
    case badStatus(Int)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let detail):
            return "Could not reach the live vehicle service: \(detail)"
        case .badStatus(let code):
            return "The live vehicle service returned HTTP \(code)."
        case .malformedResponse(let detail):
            return "The live vehicle service sent something unreadable: \(detail)"
        }
    }
}
