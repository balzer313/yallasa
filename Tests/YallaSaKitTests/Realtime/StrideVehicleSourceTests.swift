import XCTest
@testable import YallaSaKit

/// The JSON in these tests is the real shape `open-bus-stride-api.hasadna.org.il`
/// returns, trimmed to the fields the decoder reads. The awkward cases are not
/// invented: the 2038 timestamp and the repeated-snapshot rows were both taken
/// from live responses while building this.
final class StrideVehicleSourceTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-08-21T16:33:00Z")!

    private func decode(_ json: String, at moment: Date? = nil) throws -> [VehiclePosition] {
        try StrideVehicleSource.positions(
            fromJSON: Data(json.utf8),
            now: moment ?? now
        )
    }

    // MARK: - The happy path

    func testReadsPositionFromRealResponseShape() throws {
        let positions = try decode("""
        [{"id":8461502367,"siri_snapshot_id":2365899,"recorded_at_time":"2026-08-21T16:31:57+00:00",
          "lon":34.948909,"lat":32.051311,"bearing":90,"velocity":37,
          "siri_route__line_ref":16988,"siri_route__operator_ref":15,
          "siri_ride__vehicle_ref":"32317003","siri_ride__journey_ref":"2026-08-21-21076717"}]
        """)

        XCTAssertEqual(positions.count, 1)
        let vehicle = try XCTUnwrap(positions.first)
        XCTAssertEqual(vehicle.id, "32317003")
        XCTAssertEqual(vehicle.point.latitude, 32.051311, accuracy: 1e-6)
        XCTAssertEqual(vehicle.point.longitude, 34.948909, accuracy: 1e-6)
        XCTAssertEqual(vehicle.bearingDegrees, 90)
        XCTAssertEqual(vehicle.speedKilometresPerHour, 37)
        XCTAssertEqual(vehicle.journeyReference, "2026-08-21-21076717")
        XCTAssertEqual(vehicle.operatorReference, "15")
    }

    /// The line reference has to survive as the GTFS `route_id` string, because
    /// that is the only thing that joins a moving dot to a line in the graph.
    func testLineReferenceIsTheGTFSRouteIdentifier() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.05,"lon":34.94,
          "velocity":20,"bearing":10,"siri_route__line_ref":7433,"siri_ride__vehicle_ref":"v1"}]
        """)
        XCTAssertEqual(positions.first?.lineReference, "7433")
    }

    // MARK: - Corrupt timestamps

    /// The endpoint really does serve rows stamped in 2038 — the 32-bit epoch
    /// ceiling leaking out of the pipeline. Sorted newest-first they arrive
    /// *first*, so a reader that trusts the order shows a bus that has not moved
    /// since before the app existed.
    func testDropsRowsStampedInTheFuture() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2038-01-14T17:22:21+00:00","lat":32.113063,"lon":34.843994,
          "bearing":78,"velocity":0,"siri_route__line_ref":23397,"siri_ride__vehicle_ref":"ghost"},
         {"recorded_at_time":"2026-08-21T16:32:30+00:00","lat":32.05,"lon":34.79,
          "bearing":158,"velocity":14,"siri_route__line_ref":28099,"siri_ride__vehicle_ref":"real"}]
        """)

        XCTAssertEqual(positions.map(\.id), ["real"], "the 2038 row must not survive")
    }

    func testDropsRowsOlderThanTheUsableWindow() throws {
        // 40 minutes old, well past `maximumUsableAge`.
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T15:53:00+00:00","lat":32.05,"lon":34.79,
          "velocity":5,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"stale"}]
        """)
        XCTAssertTrue(positions.isEmpty)
    }

    /// A little skew between our clock and the server's is normal and must not
    /// throw away good data.
    func testToleratesSmallClockSkew() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:33:30+00:00","lat":32.05,"lon":34.79,
          "velocity":5,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"slightly-ahead"}]
        """)
        XCTAssertEqual(positions.count, 1, "30s of skew is skew, not corruption")
    }

    // MARK: - Duplicates

    /// One row per SIRI snapshot means a vehicle reporting four times in the
    /// window appears four times. Drawn naively that is a smear of markers down
    /// the road instead of one bus.
    func testKeepsOnlyTheNewestFixPerVehicle() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:30:00+00:00","lat":32.010,"lon":34.790,
          "velocity":10,"siri_route__line_ref":28099,"siri_ride__vehicle_ref":"bus-7"},
         {"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.020,"lon":34.795,
          "velocity":22,"siri_route__line_ref":28099,"siri_ride__vehicle_ref":"bus-7"},
         {"recorded_at_time":"2026-08-21T16:31:00+00:00","lat":32.015,"lon":34.792,
          "velocity":16,"siri_route__line_ref":28099,"siri_ride__vehicle_ref":"bus-7"}]
        """)

        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.point.latitude ?? 0, 32.020, accuracy: 1e-6,
                       "the 16:32 fix is the newest and must win regardless of input order")
        XCTAssertEqual(positions.first?.speedKilometresPerHour, 22)
    }

    func testDistinctVehiclesAreKept() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.01,"lon":34.79,
          "velocity":10,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"a"},
         {"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.02,"lon":34.80,
          "velocity":10,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"b"}]
        """)
        XCTAssertEqual(Set(positions.map(\.id)), ["a", "b"])
    }

    // MARK: - Bearing

    /// Feeds keep the last heading when a vehicle stops, so a parked bus carries
    /// a bearing pointing down whatever road it was on before it parked. Drawing
    /// that arrow is worse than drawing none.
    func testStationaryVehicleHasNoBearing() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.05,"lon":34.79,
          "bearing":282,"velocity":0,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"parked"}]
        """)

        let vehicle = try XCTUnwrap(positions.first)
        XCTAssertNil(vehicle.bearingDegrees)
        XCTAssertFalse(vehicle.isMoving)
    }

    func testMovingVehicleKeepsItsBearing() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.05,"lon":34.79,
          "bearing":282,"velocity":45,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"moving"}]
        """)

        let vehicle = try XCTUnwrap(positions.first)
        XCTAssertEqual(vehicle.bearingDegrees, 282)
        XCTAssertTrue(vehicle.isMoving)
    }

    // MARK: - Bad data

    func testSkipsRowsMissingCoordinates() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":null,"lon":null,
          "velocity":5,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"nowhere"},
         {"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.05,"lon":34.79,
          "velocity":5,"siri_route__line_ref":1,"siri_ride__vehicle_ref":"somewhere"}]
        """)
        XCTAssertEqual(positions.map(\.id), ["somewhere"])
    }

    func testSkipsRowsWithNoLineReference() throws {
        let positions = try decode("""
        [{"recorded_at_time":"2026-08-21T16:32:00+00:00","lat":32.05,"lon":34.79,
          "velocity":5,"siri_ride__vehicle_ref":"orphan"}]
        """)
        XCTAssertTrue(positions.isEmpty, "a position with no line cannot be attached to anything")
    }

    func testEmptyResponseIsNotAnError() throws {
        XCTAssertTrue(try decode("[]").isEmpty)
    }

    func testMalformedJSONThrowsMalformedResponse() {
        XCTAssertThrowsError(try decode("{not json")) { error in
            guard case VehiclePositionError.malformedResponse = error else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
        }
    }

    // MARK: - Timestamp parsing

    func testParsesBothISO8601Shapes() {
        XCTAssertNotNil(StrideVehicleSource.parseTimestamp("2026-08-21T16:31:57+00:00"))
        XCTAssertNotNil(StrideVehicleSource.parseTimestamp("2026-08-21T16:31:57Z"))
        XCTAssertNotNil(StrideVehicleSource.parseTimestamp("2026-08-21T16:31:57.123Z"))
        XCTAssertNil(StrideVehicleSource.parseTimestamp("yesterday"))
    }

    // MARK: - Catalogue wiring

    func testIsraeliFeedsAdvertiseLiveVehiclesButNoTripUpdates() {
        let israeli = FeedCatalog.bundled.filter { $0.countryCode == "IL" }
        XCTAssertFalse(israeli.isEmpty)
        for feed in israeli {
            XCTAssertTrue(feed.hasLiveVehicles, "\(feed.id) should offer live positions")
            XCTAssertEqual(feed.vehiclePositions, .openBusStride)
            XCTAssertFalse(feed.hasRealtime, "\(feed.id): MOT SIRI trip updates need a key")
        }
    }

    func testFeedSourceRoundTripsVehiclePositionServiceThroughJSON() throws {
        let original = try XCTUnwrap(FeedCatalog.bundled.first { $0.countryCode == "IL" })
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FeedSource.self, from: data)
        XCTAssertEqual(restored.vehiclePositions, .openBusStride)
    }

    /// A manifest written before this field existed must still install.
    func testFeedSourceDecodesWithoutVehiclePositionsField() throws {
        let json = """
        {"id":"legacy","name":"Legacy","region":"","countryCode":"IL",
         "staticURL":"https://example.org/gtfs.zip","attribution":"x",
         "approximateDownloadMegabytes":10}
        """
        let restored = try JSONDecoder().decode(FeedSource.self, from: Data(json.utf8))
        XCTAssertNil(restored.vehiclePositions)
        XCTAssertFalse(restored.hasLiveVehicles)
    }
}
