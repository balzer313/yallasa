import Foundation

// The decoded shape of the GTFS-Realtime messages the engine consumes.
//
// These are plain value types rather than a mirror of the .proto: fields the
// engine never reads are absent, optionality means "the producer omitted it"
// (which is materially different from "it sent zero" — a `delay` of 0 means *on
// time*, an absent `delay` means *unknown*), and ids stay as feed strings because
// resolving them to graph indices is `RealtimeIndex`'s job, not the decoder's.

// MARK: - Enumerations

/// `TripDescriptor.ScheduleRelationship`.
///
/// Value 4 (`REPLACEMENT`) is deprecated and never emitted by conforming
/// producers, so it is deliberately absent; an unknown value decodes to nil and
/// is treated as `.scheduled`, which is what the spec's default says.
public enum RTScheduleRelationship: Int32, Sendable, Hashable, CaseIterable {
    case scheduled = 0
    case added = 1
    case unscheduled = 2
    case canceled = 3
    case duplicated = 5
    case deleted = 7

    /// True for relationships describing a trip that does not exist in the static
    /// schedule and therefore cannot be addressed by a `TripIndex`.
    public var isUnrepresentableInStaticSchedule: Bool {
        switch self {
        case .added, .unscheduled, .duplicated: return true
        case .scheduled, .canceled, .deleted: return false
        }
    }

    /// True when the vehicle will not run at all.
    public var removesTrip: Bool {
        self == .canceled || self == .deleted
    }
}

/// `StopTimeUpdate.ScheduleRelationship`. Note this is a *different* enumeration
/// from the trip-level one and shares none of its numbering.
public enum RTStopTimeScheduleRelationship: Int32, Sendable, Hashable, CaseIterable {
    case scheduled = 0
    case skipped = 1
    case noData = 2
    case unscheduled = 3
}

/// `Alert.Effect`.
public enum RTAlertEffect: Int32, Sendable, Hashable, CaseIterable {
    case noService = 1
    case reducedService = 2
    case significantDelays = 3
    case detour = 4
    case additionalService = 5
    case modifiedService = 6
    case otherEffect = 7
    case unknownEffect = 8
    case stopMoved = 9
    case noEffect = 10
    case accessibilityIssue = 11

    public var serviceAlertEffect: ServiceAlert.Effect {
        switch self {
        case .noService: return .noService
        case .reducedService: return .reducedService
        case .significantDelays: return .significantDelays
        case .detour: return .detour
        case .additionalService: return .additionalService
        case .modifiedService: return .modifiedService
        case .otherEffect: return .otherEffect
        case .unknownEffect: return .unknownEffect
        case .stopMoved: return .stopMoved
        case .noEffect: return .noEffect
        case .accessibilityIssue: return .accessibilityIssue
        }
    }
}

/// `Alert.Cause`. Carried through for display only — nothing in the engine
/// branches on it.
public enum RTAlertCause: Int32, Sendable, Hashable, CaseIterable {
    case unknownCause = 1
    case otherCause = 2
    case technicalProblem = 3
    case strike = 4
    case demonstration = 5
    case accident = 6
    case holiday = 7
    case weather = 8
    case maintenance = 9
    case construction = 10
    case policeActivity = 11
    case medicalEmergency = 12
}

/// `Alert.SeverityLevel`.
public enum RTAlertSeverity: Int32, Sendable, Hashable, CaseIterable {
    case unknownSeverity = 1
    case info = 2
    case warning = 3
    case severe = 4

    public var serviceAlertSeverity: ServiceAlert.Severity {
        switch self {
        case .unknownSeverity: return .unknown
        case .info: return .info
        case .warning: return .warning
        case .severe: return .severe
        }
    }
}

// MARK: - Descriptors

/// `TripDescriptor` — which scheduled trip a message is about.
public struct RTTripDescriptor: Sendable, Hashable {
    public var tripID: String?
    public var routeID: String?
    public var directionID: UInt32?
    /// `HH:MM:SS` as the feed wrote it. Only meaningful for frequency-based trips,
    /// which the graph has already expanded, so nothing consumes it yet.
    public var startTime: String?
    /// Parsed from the wire's `YYYYMMDD`. Unparsable dates decode to nil rather
    /// than failing the message.
    public var startDate: ServiceDate?
    /// Nil when the producer omitted the field; the spec's default is `.scheduled`.
    public var scheduleRelationship: RTScheduleRelationship?

    public init(
        tripID: String? = nil,
        routeID: String? = nil,
        directionID: UInt32? = nil,
        startTime: String? = nil,
        startDate: ServiceDate? = nil,
        scheduleRelationship: RTScheduleRelationship? = nil
    ) {
        self.tripID = tripID
        self.routeID = routeID
        self.directionID = directionID
        self.startTime = startTime
        self.startDate = startDate
        self.scheduleRelationship = scheduleRelationship
    }

    /// The relationship to assume when the producer omitted the field.
    public var effectiveScheduleRelationship: RTScheduleRelationship {
        scheduleRelationship ?? .scheduled
    }
}

/// `VehicleDescriptor` — which physical vehicle, for labelling only.
public struct RTVehicleDescriptor: Sendable, Hashable {
    public var id: String?
    public var label: String?
    public var licensePlate: String?

    public init(id: String? = nil, label: String? = nil, licensePlate: String? = nil) {
        self.id = id
        self.label = label
        self.licensePlate = licensePlate
    }
}

// MARK: - Trip updates

/// `StopTimeEvent` — one side (arrival or departure) of a predicted stop time.
///
/// Exactly one of `delay` and `time` is normally present. `time` is absolute
/// POSIX seconds; converting it to a delay needs the scheduled time out of the
/// graph, which is why that conversion lives in `RealtimeIndex` and not here.
public struct RTStopTimeEvent: Sendable, Hashable {
    public var delay: Int32?
    public var time: Int64?
    public var uncertainty: Int32?

    public init(delay: Int32? = nil, time: Int64? = nil, uncertainty: Int32? = nil) {
        self.delay = delay
        self.time = time
        self.uncertainty = uncertainty
    }
}

/// `TripUpdate.StopTimeUpdate` — a prediction for one stop of one trip.
public struct RTStopTimeUpdate: Sendable, Hashable {
    /// The GTFS `stop_times.stop_sequence` value. Emphatically *not* an index
    /// into the pattern: feeds are free to number 1, 2, 3… or 10, 20, 30….
    public var stopSequence: UInt32?
    public var stopID: String?
    public var arrival: RTStopTimeEvent?
    public var departure: RTStopTimeEvent?
    public var scheduleRelationship: RTStopTimeScheduleRelationship

    public init(
        stopSequence: UInt32? = nil,
        stopID: String? = nil,
        arrival: RTStopTimeEvent? = nil,
        departure: RTStopTimeEvent? = nil,
        scheduleRelationship: RTStopTimeScheduleRelationship = .scheduled
    ) {
        self.stopSequence = stopSequence
        self.stopID = stopID
        self.arrival = arrival
        self.departure = departure
        self.scheduleRelationship = scheduleRelationship
    }
}

/// `TripUpdate` — the message that actually changes routing results.
public struct RTTripUpdate: Sendable, Hashable {
    /// `FeedEntity.id`, kept so a diagnostic can name the offending entity.
    public var entityID: String
    public var trip: RTTripDescriptor
    public var vehicle: RTVehicleDescriptor?
    public var stopTimeUpdates: [RTStopTimeUpdate]
    /// POSIX seconds; when the prediction itself was made.
    public var timestamp: UInt64?
    /// Trip-level delay, applying to every stop with no more specific update.
    public var delay: Int32?

    public init(
        entityID: String = "",
        trip: RTTripDescriptor = RTTripDescriptor(),
        vehicle: RTVehicleDescriptor? = nil,
        stopTimeUpdates: [RTStopTimeUpdate] = [],
        timestamp: UInt64? = nil,
        delay: Int32? = nil
    ) {
        self.entityID = entityID
        self.trip = trip
        self.vehicle = vehicle
        self.stopTimeUpdates = stopTimeUpdates
        self.timestamp = timestamp
        self.delay = delay
    }
}

// MARK: - Vehicle positions

/// `Position` — where a vehicle is, in WGS-84.
public struct RTPosition: Sendable, Hashable {
    public var latitude: Float
    public var longitude: Float
    public var bearing: Float?
    public var odometer: Double?
    /// Metres per second.
    public var speed: Float?

    public init(
        latitude: Float = 0,
        longitude: Float = 0,
        bearing: Float? = nil,
        odometer: Double? = nil,
        speed: Float? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.bearing = bearing
        self.odometer = odometer
        self.speed = speed
    }
}

/// `VehiclePosition` — a moving dot on the map. Nothing in the router reads this;
/// it exists so the trip-detail screen can show the bus.
public struct RTVehiclePosition: Sendable, Hashable {
    public var entityID: String
    public var trip: RTTripDescriptor?
    public var vehicle: RTVehicleDescriptor?
    public var position: RTPosition?
    public var currentStopSequence: UInt32?
    public var stopID: String?
    public var timestamp: UInt64?
    /// Raw enum values, kept unmapped because no UI consumes them yet.
    public var congestionLevel: Int32?
    public var occupancyStatus: Int32?

    public init(
        entityID: String = "",
        trip: RTTripDescriptor? = nil,
        vehicle: RTVehicleDescriptor? = nil,
        position: RTPosition? = nil,
        currentStopSequence: UInt32? = nil,
        stopID: String? = nil,
        timestamp: UInt64? = nil,
        congestionLevel: Int32? = nil,
        occupancyStatus: Int32? = nil
    ) {
        self.entityID = entityID
        self.trip = trip
        self.vehicle = vehicle
        self.position = position
        self.currentStopSequence = currentStopSequence
        self.stopID = stopID
        self.timestamp = timestamp
        self.congestionLevel = congestionLevel
        self.occupancyStatus = occupancyStatus
    }
}

// MARK: - Alerts

/// `TimeRange` — POSIX seconds; an absent bound means "open-ended".
public struct RTTimeRange: Sendable, Hashable {
    public var start: UInt64?
    public var end: UInt64?

    public init(start: UInt64? = nil, end: UInt64? = nil) {
        self.start = start
        self.end = end
    }
}

/// `EntitySelector` — what an alert is about.
public struct RTEntitySelector: Sendable, Hashable {
    public var agencyID: String?
    public var routeID: String?
    public var routeType: Int32?
    public var trip: RTTripDescriptor?
    public var stopID: String?
    public var directionID: UInt32?

    public init(
        agencyID: String? = nil,
        routeID: String? = nil,
        routeType: Int32? = nil,
        trip: RTTripDescriptor? = nil,
        stopID: String? = nil,
        directionID: UInt32? = nil
    ) {
        self.agencyID = agencyID
        self.routeID = routeID
        self.routeType = routeType
        self.trip = trip
        self.stopID = stopID
        self.directionID = directionID
    }
}

/// `Alert` — rider-facing prose plus what it applies to.
///
/// The translated strings have already been collapsed to one language by the
/// decoder; carrying every translation to the UI would mean the UI owning the
/// language-matching rule, and there is exactly one right answer for it.
public struct RTAlert: Sendable, Hashable {
    public var entityID: String
    public var activePeriods: [RTTimeRange]
    public var informedEntities: [RTEntitySelector]
    public var cause: RTAlertCause?
    public var effect: RTAlertEffect?
    public var url: String?
    public var headerText: String
    public var descriptionText: String
    public var severityLevel: RTAlertSeverity?

    public init(
        entityID: String = "",
        activePeriods: [RTTimeRange] = [],
        informedEntities: [RTEntitySelector] = [],
        cause: RTAlertCause? = nil,
        effect: RTAlertEffect? = nil,
        url: String? = nil,
        headerText: String = "",
        descriptionText: String = "",
        severityLevel: RTAlertSeverity? = nil
    ) {
        self.entityID = entityID
        self.activePeriods = activePeriods
        self.informedEntities = informedEntities
        self.cause = cause
        self.effect = effect
        self.url = url
        self.headerText = headerText
        self.descriptionText = descriptionText
        self.severityLevel = severityLevel
    }
}
