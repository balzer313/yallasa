import XCTest
@testable import YallaSaKit

/// A minimal protobuf *encoder*, so the expected bytes below read as a message
/// rather than as a wall of hex.
///
/// It intentionally shares no code with `ProtobufReader`: a test that encoded
/// with the decoder's own primitives would agree with itself about a wrong wire
/// format. Everything here is written straight from the encoding spec.
private struct ProtobufTestEncoder {
    private(set) var bytes: [UInt8] = []

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
    }

    private mutating func appendTag(_ number: Int, _ wireType: UInt8) {
        appendVarint((UInt64(number) << 3) | UInt64(wireType))
    }

    mutating func varint(_ number: Int, _ value: UInt64) {
        appendTag(number, 0)
        appendVarint(value)
    }

    /// Plain `int32`/`int64`: negatives are sign-extended to 64 bits, which is
    /// what makes `-60` ten bytes long on the wire.
    mutating func signed(_ number: Int, _ value: Int64) {
        appendTag(number, 0)
        appendVarint(UInt64(bitPattern: value))
    }

    mutating func string(_ number: Int, _ value: String) {
        appendTag(number, 2)
        let payload = Array(value.utf8)
        appendVarint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    mutating func message(_ number: Int, _ payload: [UInt8]) {
        appendTag(number, 2)
        appendVarint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    mutating func message(_ number: Int, _ build: (inout ProtobufTestEncoder) -> Void) {
        var nested = ProtobufTestEncoder()
        build(&nested)
        message(number, nested.bytes)
    }

    mutating func float(_ number: Int, _ value: Float) {
        appendTag(number, 5)
        let pattern = value.bitPattern
        bytes.append(UInt8(pattern & 0xFF))
        bytes.append(UInt8((pattern >> 8) & 0xFF))
        bytes.append(UInt8((pattern >> 16) & 0xFF))
        bytes.append(UInt8((pattern >> 24) & 0xFF))
    }

    var data: Data { Data(bytes) }

    static func encode(_ build: (inout ProtobufTestEncoder) -> Void) -> Data {
        var encoder = ProtobufTestEncoder()
        build(&encoder)
        return encoder.data
    }
}

final class GTFSRealtimeDecoderTests: XCTestCase {

    /// 2026-08-09T12:00:00Z, which is also the `start_date` used below.
    private let feedTimestamp: UInt64 = 1_786_636_800

    private func makeFeedMessage() -> Data {
        ProtobufTestEncoder.encode { feed in
            // FeedHeader
            feed.message(1) { header in
                header.string(1, "2.0")             // gtfs_realtime_version
                header.varint(2, 0)                 // incrementality = FULL_DATASET
                header.varint(3, self.feedTimestamp)
            }

            // A field number no version of the spec defines. It must be skipped.
            feed.varint(99, 1234)

            // FeedEntity carrying a TripUpdate
            feed.message(2) { entity in
                entity.string(1, "entity-1")
                entity.message(3) { update in
                    update.message(1) { trip in     // TripDescriptor
                        trip.string(1, "T1")        // trip_id
                        trip.string(3, "20260809")  // start_date
                        trip.varint(4, 0)           // SCHEDULED
                        trip.string(5, "R1")        // route_id
                        trip.varint(6, 1)           // direction_id
                    }
                    update.message(2) { stop in     // first StopTimeUpdate
                        stop.varint(1, 1)           // stop_sequence
                        stop.message(2) { event in  // arrival
                            encodeStopTimeEvent(&event, delay: 30)
                        }
                        stop.message(3) { event in  // departure
                            encodeStopTimeEvent(&event, delay: 45)
                        }
                        stop.string(4, "S1")        // stop_id
                    }
                    update.message(2) { stop in     // second StopTimeUpdate
                        stop.varint(1, 2)
                        stop.message(3) { event in  // departure only, running early
                            encodeStopTimeEvent(&event, delay: -60)
                        }
                        stop.string(4, "S2")
                        stop.varint(5, 1)           // SKIPPED
                    }
                    update.message(3) { vehicle in  // VehicleDescriptor
                        vehicle.string(1, "bus-7")
                        vehicle.string(2, "7")
                    }
                    update.varint(4, self.feedTimestamp)
                    update.signed(5, -30)           // trip-level delay
                    update.string(42, "a field from the future")
                }
            }

            // FeedEntity carrying a VehiclePosition
            feed.message(2) { entity in
                entity.string(1, "entity-2")
                entity.message(4) { vehicle in
                    vehicle.message(1) { trip in
                        trip.string(1, "T1")
                    }
                    vehicle.message(2) { position in
                        position.float(1, 32.0853)
                        position.float(2, 34.7818)
                        position.float(3, 180)
                    }
                    vehicle.varint(3, 2)            // current_stop_sequence
                    vehicle.varint(4, self.feedTimestamp)
                    vehicle.string(7, "S2")
                }
            }

            // FeedEntity carrying an Alert
            feed.message(2) { entity in
                entity.string(1, "entity-3")
                entity.message(5) { alert in
                    alert.message(1) { period in
                        period.varint(1, self.feedTimestamp)
                        period.varint(2, self.feedTimestamp + 3600)
                    }
                    alert.message(5) { selector in
                        selector.string(2, "R1")
                    }
                    alert.message(5) { selector in
                        selector.string(5, "S2")
                    }
                    alert.varint(6, 3)              // cause = TECHNICAL_PROBLEM
                    alert.varint(7, 4)              // effect = DETOUR
                    alert.message(8) { url in
                        url.message(1) { translation in
                            translation.string(1, "https://example.test/alert")
                            translation.string(2, "zz")
                        }
                    }
                    alert.message(10) { header in
                        header.message(1) { translation in
                            translation.string(1, "Roadworks on Line 1")
                            translation.string(2, "zz")
                        }
                        header.message(1) { translation in
                            translation.string(1, "Travaux sur la ligne 1")
                            translation.string(2, "xx")
                        }
                    }
                    alert.message(11) { body in
                        body.message(1) { translation in
                            translation.string(1, "Buses are being diverted.")
                            translation.string(2, "zz")
                        }
                    }
                    alert.varint(14, 3)             // severity = WARNING
                }
            }
        }
    }

    /// `StopTimeEvent`: 1 delay, 2 time, 3 uncertainty.
    private func encodeStopTimeEvent(_ encoder: inout ProtobufTestEncoder, delay: Int64) {
        encoder.signed(1, delay)
    }

    // MARK: - Tests

    func testHeaderTimestampBecomesGeneratedAt() throws {
        let feed = try GTFSRealtimeDecoder.decode(makeFeedMessage())
        XCTAssertEqual(feed.generatedAt.timeIntervalSince1970, TimeInterval(feedTimestamp), accuracy: 0.5)
    }

    func testTripUpdateDecodes() throws {
        let feed = try GTFSRealtimeDecoder.decode(makeFeedMessage())
        XCTAssertEqual(feed.tripUpdates.count, 1)
        let update = try XCTUnwrap(feed.tripUpdates.first)

        XCTAssertEqual(update.entityID, "entity-1")
        XCTAssertEqual(update.trip.tripID, "T1")
        XCTAssertEqual(update.trip.routeID, "R1")
        XCTAssertEqual(update.trip.directionID, 1)
        XCTAssertEqual(update.trip.startDate, ServiceDate(year: 2026, month: 8, day: 9))
        XCTAssertEqual(update.trip.scheduleRelationship, .scheduled)
        XCTAssertEqual(update.vehicle?.id, "bus-7")
        XCTAssertEqual(update.vehicle?.label, "7")
        XCTAssertEqual(update.timestamp, feedTimestamp)
        XCTAssertEqual(update.delay, -30)
    }

    func testStopTimeUpdatesKeepTheirOrderAndSigns() throws {
        let feed = try GTFSRealtimeDecoder.decode(makeFeedMessage())
        let update = try XCTUnwrap(feed.tripUpdates.first)
        XCTAssertEqual(update.stopTimeUpdates.count, 2)

        let first = update.stopTimeUpdates[0]
        XCTAssertEqual(first.stopSequence, 1)
        XCTAssertEqual(first.stopID, "S1")
        XCTAssertEqual(first.arrival?.delay, 30)
        XCTAssertEqual(first.departure?.delay, 45)
        XCTAssertEqual(first.scheduleRelationship, .scheduled)

        let second = update.stopTimeUpdates[1]
        XCTAssertEqual(second.stopSequence, 2)
        XCTAssertEqual(second.stopID, "S2")
        XCTAssertNil(second.arrival)
        // The ten-byte negative varint, decoded back to a small negative number.
        XCTAssertEqual(second.departure?.delay, -60)
        XCTAssertEqual(second.scheduleRelationship, .skipped)
    }

    func testVehiclePositionDecodes() throws {
        let feed = try GTFSRealtimeDecoder.decode(makeFeedMessage())
        XCTAssertEqual(feed.vehiclePositions.count, 1)
        let vehicle = try XCTUnwrap(feed.vehiclePositions.first)
        XCTAssertEqual(vehicle.entityID, "entity-2")
        XCTAssertEqual(vehicle.trip?.tripID, "T1")
        XCTAssertEqual(vehicle.position?.latitude ?? 0, 32.0853, accuracy: 0.0001)
        XCTAssertEqual(vehicle.position?.longitude ?? 0, 34.7818, accuracy: 0.0001)
        XCTAssertEqual(vehicle.position?.bearing ?? 0, 180, accuracy: 0.0001)
        XCTAssertEqual(vehicle.currentStopSequence, 2)
        XCTAssertEqual(vehicle.stopID, "S2")
    }

    func testAlertDecodes() throws {
        let feed = try GTFSRealtimeDecoder.decode(makeFeedMessage())
        XCTAssertEqual(feed.alerts.count, 1)
        let alert = try XCTUnwrap(feed.alerts.first)

        XCTAssertEqual(alert.entityID, "entity-3")
        XCTAssertEqual(alert.cause, .technicalProblem)
        XCTAssertEqual(alert.effect, .detour)
        XCTAssertEqual(alert.severityLevel, .warning)
        XCTAssertEqual(alert.url, "https://example.test/alert")
        // Neither translation is in a language any device runs, so the first one
        // wins — which is the documented fallback.
        XCTAssertEqual(alert.headerText, "Roadworks on Line 1")
        XCTAssertEqual(alert.descriptionText, "Buses are being diverted.")
        XCTAssertEqual(alert.activePeriods.count, 1)
        XCTAssertEqual(alert.activePeriods.first?.start, feedTimestamp)
        XCTAssertEqual(alert.activePeriods.first?.end, feedTimestamp + 3600)
        XCTAssertEqual(alert.informedEntities.count, 2)
        XCTAssertEqual(alert.informedEntities[0].routeID, "R1")
        XCTAssertEqual(alert.informedEntities[1].stopID, "S2")
    }

    // MARK: - Robustness

    func testUnknownEnumValueFallsBackToTheDefault() throws {
        let data = ProtobufTestEncoder.encode { feed in
            feed.message(2) { entity in
                entity.string(1, "e")
                entity.message(3) { update in
                    update.message(1) { trip in
                        trip.string(1, "T1")
                        trip.varint(4, 77)          // no such schedule relationship
                    }
                    update.message(2) { stop in
                        stop.varint(1, 0)
                        stop.varint(5, 99)          // no such stop relationship
                    }
                }
            }
        }
        let feed = try GTFSRealtimeDecoder.decode(data)
        let update = try XCTUnwrap(feed.tripUpdates.first)
        XCTAssertNil(update.trip.scheduleRelationship)
        XCTAssertEqual(update.trip.effectiveScheduleRelationship, .scheduled)
        XCTAssertEqual(update.stopTimeUpdates.first?.scheduleRelationship, .scheduled)
    }

    func testUnparsableStartDateIsDroppedNotFatal() throws {
        let data = ProtobufTestEncoder.encode { feed in
            feed.message(2) { entity in
                entity.message(3) { update in
                    update.message(1) { trip in
                        trip.string(1, "T1")
                        trip.string(3, "not-a-date")
                    }
                }
            }
        }
        let feed = try GTFSRealtimeDecoder.decode(data)
        XCTAssertEqual(feed.tripUpdates.count, 1)
        XCTAssertNil(feed.tripUpdates.first?.trip.startDate)
        XCTAssertEqual(feed.tripUpdates.first?.trip.tripID, "T1")
    }

    func testDeletedEntitiesAreDropped() throws {
        let data = ProtobufTestEncoder.encode { feed in
            feed.message(2) { entity in
                entity.string(1, "gone")
                entity.varint(2, 1)                 // is_deleted
                entity.message(3) { update in
                    update.message(1) { trip in trip.string(1, "T1") }
                }
            }
        }
        let feed = try GTFSRealtimeDecoder.decode(data)
        XCTAssertTrue(feed.tripUpdates.isEmpty)
    }

    func testEmptyPayloadThrows() {
        XCTAssertThrowsError(try GTFSRealtimeDecoder.decode(Data())) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
    }

    func testTruncatedPayloadThrows() {
        var bytes = Array(makeFeedMessage())
        bytes.removeLast(bytes.count / 3)
        XCTAssertThrowsError(try GTFSRealtimeDecoder.decode(Data(bytes)))
    }

    func testGarbageDoesNotCrash() {
        // Not an assertion about the result — only that a hostile body either
        // decodes to something or throws, and never reads out of bounds.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let length = Int.random(in: 1...64, using: &generator)
            var bytes: [UInt8] = []
            for _ in 0..<length { bytes.append(UInt8.random(in: 0...255, using: &generator)) }
            _ = try? GTFSRealtimeDecoder.decode(Data(bytes))
        }
    }
}
