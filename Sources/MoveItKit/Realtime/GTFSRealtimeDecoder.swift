import Foundation

/// One decoded `FeedMessage`.
///
/// A snapshot, not a stream: GTFS-Realtime's `DIFFERENTIAL` incrementality is
/// specified but effectively unused in the wild, and applying diffs would mean
/// keeping mutable state across fetches. Every feed is treated as a full
/// replacement, which is what `FULL_DATASET` producers — that is, all of them —
/// intend.
public struct GTFSRealtimeFeed: Sendable {
    public var generatedAt: Date
    public var tripUpdates: [RTTripUpdate]
    public var vehiclePositions: [RTVehiclePosition]
    public var alerts: [RTAlert]

    public init(
        generatedAt: Date = Date(),
        tripUpdates: [RTTripUpdate] = [],
        vehiclePositions: [RTVehiclePosition] = [],
        alerts: [RTAlert] = []
    ) {
        self.generatedAt = generatedAt
        self.tripUpdates = tripUpdates
        self.vehiclePositions = vehiclePositions
        self.alerts = alerts
    }

    /// Merges another feed's entities into this one, keeping the newer header
    /// time. Agencies routinely split trip updates, vehicle positions and alerts
    /// across separate endpoints, and the engine wants one snapshot.
    public func merging(_ other: GTFSRealtimeFeed) -> GTFSRealtimeFeed {
        GTFSRealtimeFeed(
            generatedAt: max(generatedAt, other.generatedAt),
            tripUpdates: tripUpdates + other.tripUpdates,
            vehiclePositions: vehiclePositions + other.vehiclePositions,
            alerts: alerts + other.alerts
        )
    }
}

/// Turns `FeedMessage` bytes into `GTFSRealtimeFeed`.
///
/// Hand-written against the published field numbers rather than generated from
/// the `.proto`, because the project takes no third-party dependency and
/// SwiftProtobuf's generated code would be one. The field numbers are frozen by
/// the specification — they are as stable as the wire format itself — so the
/// maintenance cost of writing them out is a one-off.
///
/// The decoder's contract with the network is that **no input fails the parse
/// except bytes that are not protobuf at all**. Unknown fields are skipped by
/// wire type, unknown enum values decode to nil, and unparsable dates decode to
/// nil. Producers add fields without notice and a stricter reader would go dark
/// on a Tuesday morning for no reason the rider could understand.
public enum GTFSRealtimeDecoder {

    public static func decode(_ data: Data) throws -> GTFSRealtimeFeed {
        guard !data.isEmpty else { throw ProtobufError.truncated }
        let language = preferredLanguageCode()
        return try data.withUnsafeBytes { raw in
            try decodeFeedMessage(raw, language: language)
        }
    }

    // MARK: - FeedMessage

    private static func decodeFeedMessage(
        _ bytes: UnsafeRawBufferPointer,
        language: String
    ) throws -> GTFSRealtimeFeed {
        var reader = ProtobufReader(bytes: bytes)
        var headerTimestamp: UInt64 = 0
        var tripUpdates: [RTTripUpdate] = []
        var vehiclePositions: [RTVehiclePosition] = []
        var alerts: [RTAlert] = []

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                headerTimestamp = try decodeFeedHeaderTimestamp(payload)
            case (2, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                try decodeFeedEntity(
                    payload,
                    language: language,
                    tripUpdates: &tripUpdates,
                    vehiclePositions: &vehiclePositions,
                    alerts: &alerts
                )
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }

        // A feed with no header timestamp is out of spec but not rare. Dating it
        // "now" is the honest reading: we know nothing about how old it is, and
        // pretending it is from 1970 would make every snapshot look stale.
        let generatedAt = headerTimestamp > 0
            ? Date(timeIntervalSince1970: TimeInterval(headerTimestamp))
            : Date()

        return GTFSRealtimeFeed(
            generatedAt: generatedAt,
            tripUpdates: tripUpdates,
            vehiclePositions: vehiclePositions,
            alerts: alerts
        )
    }

    /// `FeedHeader`: 1 gtfs_realtime_version, 2 incrementality, 3 timestamp.
    private static func decodeFeedHeaderTimestamp(_ bytes: UnsafeRawBufferPointer) throws -> UInt64 {
        var reader = ProtobufReader(bytes: bytes)
        var timestamp: UInt64 = 0
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (3, .varint):
                timestamp = try reader.readVarint()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return timestamp
    }

    /// `FeedEntity`: 1 id, 2 is_deleted, 3 trip_update, 4 vehicle, 5 alert.
    ///
    /// Payloads are collected first and decoded afterwards, because the entity id
    /// is field 1 only by convention — nothing in the wire format guarantees a
    /// producer writes fields in order.
    private static func decodeFeedEntity(
        _ bytes: UnsafeRawBufferPointer,
        language: String,
        tripUpdates: inout [RTTripUpdate],
        vehiclePositions: inout [RTVehiclePosition],
        alerts: inout [RTAlert]
    ) throws {
        var reader = ProtobufReader(bytes: bytes)
        var identifier = ""
        var isDeleted = false
        var tripUpdateBytes: UnsafeRawBufferPointer?
        var vehicleBytes: UnsafeRawBufferPointer?
        var alertBytes: UnsafeRawBufferPointer?

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                identifier = try reader.readString()
            case (2, .varint):
                isDeleted = try reader.readBool()
            case (3, .lengthDelimited):
                tripUpdateBytes = try reader.readLengthDelimited()
            case (4, .lengthDelimited):
                vehicleBytes = try reader.readLengthDelimited()
            case (5, .lengthDelimited):
                alertBytes = try reader.readLengthDelimited()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }

        // `is_deleted` is only meaningful in a differential feed, which we do not
        // apply. Dropping the entity is the safe reading either way.
        guard !isDeleted else { return }

        if let tripUpdateBytes {
            var update = try decodeTripUpdate(tripUpdateBytes)
            update.entityID = identifier
            tripUpdates.append(update)
        }
        if let vehicleBytes {
            var position = try decodeVehiclePosition(vehicleBytes)
            position.entityID = identifier
            vehiclePositions.append(position)
        }
        if let alertBytes {
            var alert = try decodeAlert(alertBytes, language: language)
            alert.entityID = identifier
            alerts.append(alert)
        }
    }

    // MARK: - TripUpdate

    /// `TripUpdate`: 1 trip, 2 stop_time_update, 3 vehicle, 4 timestamp, 5 delay.
    private static func decodeTripUpdate(_ bytes: UnsafeRawBufferPointer) throws -> RTTripUpdate {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTTripUpdate()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.trip = try decodeTripDescriptor(payload)
            case (2, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                let update = try decodeStopTimeUpdate(payload)
                result.stopTimeUpdates.append(update)
            case (3, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.vehicle = try decodeVehicleDescriptor(payload)
            case (4, .varint):
                result.timestamp = try reader.readVarint()
            case (5, .varint):
                result.delay = try reader.readInt32()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `TripDescriptor`: 1 trip_id, 2 start_time, 3 start_date, 4
    /// schedule_relationship, 5 route_id, 6 direction_id.
    private static func decodeTripDescriptor(_ bytes: UnsafeRawBufferPointer) throws -> RTTripDescriptor {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTTripDescriptor()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                result.tripID = try reader.readString()
            case (2, .lengthDelimited):
                result.startTime = try reader.readString()
            case (3, .lengthDelimited):
                let text = try reader.readString()
                result.startDate = ServiceDate(gtfs: text)
            case (4, .varint):
                let raw = try reader.readInt32()
                result.scheduleRelationship = RTScheduleRelationship(rawValue: raw)
            case (5, .lengthDelimited):
                result.routeID = try reader.readString()
            case (6, .varint):
                result.directionID = try reader.readUInt32()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `StopTimeUpdate`: 1 stop_sequence, 2 arrival, 3 departure, 4 stop_id,
    /// 5 schedule_relationship.
    private static func decodeStopTimeUpdate(_ bytes: UnsafeRawBufferPointer) throws -> RTStopTimeUpdate {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTStopTimeUpdate()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                result.stopSequence = try reader.readUInt32()
            case (2, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.arrival = try decodeStopTimeEvent(payload)
            case (3, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.departure = try decodeStopTimeEvent(payload)
            case (4, .lengthDelimited):
                result.stopID = try reader.readString()
            case (5, .varint):
                let raw = try reader.readInt32()
                if let relationship = RTStopTimeScheduleRelationship(rawValue: raw) {
                    result.scheduleRelationship = relationship
                }
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `StopTimeEvent`: 1 delay, 2 time, 3 uncertainty.
    private static func decodeStopTimeEvent(_ bytes: UnsafeRawBufferPointer) throws -> RTStopTimeEvent {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTStopTimeEvent()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                result.delay = try reader.readInt32()
            case (2, .varint):
                result.time = try reader.readInt64()
            case (3, .varint):
                result.uncertainty = try reader.readInt32()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    // MARK: - VehiclePosition

    /// `VehiclePosition`: 1 trip, 2 position, 3 current_stop_sequence,
    /// 4 timestamp, 5 congestion_level, 6 occupancy_status, 7 stop_id, 8 vehicle.
    private static func decodeVehiclePosition(_ bytes: UnsafeRawBufferPointer) throws -> RTVehiclePosition {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTVehiclePosition()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.trip = try decodeTripDescriptor(payload)
            case (2, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.position = try decodePosition(payload)
            case (3, .varint):
                result.currentStopSequence = try reader.readUInt32()
            case (4, .varint):
                result.timestamp = try reader.readVarint()
            case (5, .varint):
                result.congestionLevel = try reader.readInt32()
            case (6, .varint):
                result.occupancyStatus = try reader.readInt32()
            case (7, .lengthDelimited):
                result.stopID = try reader.readString()
            case (8, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.vehicle = try decodeVehicleDescriptor(payload)
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `Position`: 1 latitude, 2 longitude, 3 bearing, 4 odometer, 5 speed.
    private static func decodePosition(_ bytes: UnsafeRawBufferPointer) throws -> RTPosition {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTPosition()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .fixed32):
                result.latitude = try reader.readFloat()
            case (2, .fixed32):
                result.longitude = try reader.readFloat()
            case (3, .fixed32):
                result.bearing = try reader.readFloat()
            case (4, .fixed64):
                result.odometer = try reader.readDouble()
            case (5, .fixed32):
                result.speed = try reader.readFloat()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `VehicleDescriptor`: 1 id, 2 label, 3 license_plate.
    private static func decodeVehicleDescriptor(_ bytes: UnsafeRawBufferPointer) throws -> RTVehicleDescriptor {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTVehicleDescriptor()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                result.id = try reader.readString()
            case (2, .lengthDelimited):
                result.label = try reader.readString()
            case (3, .lengthDelimited):
                result.licensePlate = try reader.readString()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    // MARK: - Alert

    /// `Alert`: 1 active_period, 5 informed_entity, 6 cause, 7 effect, 8 url,
    /// 10 header_text, 11 description_text, 14 severity_level.
    private static func decodeAlert(
        _ bytes: UnsafeRawBufferPointer,
        language: String
    ) throws -> RTAlert {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTAlert()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                let range = try decodeTimeRange(payload)
                result.activePeriods.append(range)
            case (5, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                let selector = try decodeEntitySelector(payload)
                result.informedEntities.append(selector)
            case (6, .varint):
                let raw = try reader.readInt32()
                result.cause = RTAlertCause(rawValue: raw)
            case (7, .varint):
                let raw = try reader.readInt32()
                result.effect = RTAlertEffect(rawValue: raw)
            case (8, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                let text = try decodeTranslatedString(payload, language: language)
                result.url = text.isEmpty ? nil : text
            case (10, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.headerText = try decodeTranslatedString(payload, language: language)
            case (11, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.descriptionText = try decodeTranslatedString(payload, language: language)
            case (14, .varint):
                let raw = try reader.readInt32()
                result.severityLevel = RTAlertSeverity(rawValue: raw)
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `TimeRange`: 1 start, 2 end.
    private static func decodeTimeRange(_ bytes: UnsafeRawBufferPointer) throws -> RTTimeRange {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTTimeRange()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                result.start = try reader.readVarint()
            case (2, .varint):
                result.end = try reader.readVarint()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    /// `EntitySelector`: 1 agency_id, 2 route_id, 3 route_type, 4 trip,
    /// 5 stop_id, 6 direction_id.
    private static func decodeEntitySelector(_ bytes: UnsafeRawBufferPointer) throws -> RTEntitySelector {
        var reader = ProtobufReader(bytes: bytes)
        var result = RTEntitySelector()
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                result.agencyID = try reader.readString()
            case (2, .lengthDelimited):
                result.routeID = try reader.readString()
            case (3, .varint):
                result.routeType = try reader.readInt32()
            case (4, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                result.trip = try decodeTripDescriptor(payload)
            case (5, .lengthDelimited):
                result.stopID = try reader.readString()
            case (6, .varint):
                result.directionID = try reader.readUInt32()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return result
    }

    // MARK: - Translated strings

    /// `TranslatedString`: 1 translation (repeated `Translation`).
    ///
    /// Picks the device's language when the feed offers it and the first
    /// translation otherwise. Bilingual regions publish alerts in two or three
    /// languages and showing a rider the wrong one is worse than showing them a
    /// generic delay banner.
    private static func decodeTranslatedString(
        _ bytes: UnsafeRawBufferPointer,
        language: String
    ) throws -> String {
        var reader = ProtobufReader(bytes: bytes)
        var firstText: String?
        var matchedText: String?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                let translation = try decodeTranslation(payload)
                if firstText == nil { firstText = translation.text }
                if matchedText == nil, matches(translation.language, language) {
                    matchedText = translation.text
                }
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return matchedText ?? firstText ?? ""
    }

    /// `Translation`: 1 text, 2 language.
    private static func decodeTranslation(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> (text: String, language: String) {
        var reader = ProtobufReader(bytes: bytes)
        var text = ""
        var language = ""
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                text = try reader.readString()
            case (2, .lengthDelimited):
                language = try reader.readString()
            default:
                try reader.skipField(wireType: field.wireType)
            }
        }
        return (text: text, language: language)
    }

    /// Compares only the primary subtag, so `pt-BR` matches a device set to `pt`.
    private static func matches(_ translationLanguage: String, _ deviceLanguage: String) -> Bool {
        guard !translationLanguage.isEmpty, !deviceLanguage.isEmpty else { return false }
        return primarySubtag(translationLanguage) == primarySubtag(deviceLanguage)
    }

    private static func primarySubtag(_ tag: String) -> String {
        let lowercased = tag.lowercased()
        if let separator = lowercased.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(lowercased[lowercased.startIndex..<separator])
        }
        return lowercased
    }

    private static func preferredLanguageCode() -> String {
        if let preferred = Locale.preferredLanguages.first, !preferred.isEmpty {
            return primarySubtag(preferred)
        }
        return primarySubtag(Locale.current.identifier)
    }
}
