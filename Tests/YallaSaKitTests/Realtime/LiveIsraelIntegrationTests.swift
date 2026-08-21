import XCTest
@testable import YallaSaKit

/// Hits the real Open Bus API with the real client.
///
/// The unit tests in `StrideVehicleSourceTests` feed captured JSON. That proves
/// the parsing and nothing about the endpoint: the live feature depends on a
/// third-party community service that can change shape, rate-limit, or vanish
/// without telling anyone, and every one of those unit tests would stay green
/// throughout.
///
/// **Skipped unless `YALLASA_LIVE_TESTS=1`.** A network test that fails when
/// someone else's server is slow trains people to ignore red builds, so this
/// never runs in ordinary CI — only from the `Live Israel check` workflow.
final class LiveIsraelIntegrationTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["YALLASA_LIVE_TESTS"] == "1"
    }

    /// Tel Aviv metro, generously boxed.
    private let telAviv = GeoBounds(
        minLatitude: 31.95, minLongitude: 34.65,
        maxLatitude: 32.20, maxLongitude: 34.95
    )

    /// The whole country, for the "is anything running at all" check.
    private let israel = GeoBounds(
        minLatitude: 29.45, minLongitude: 34.20,
        maxLatitude: 33.35, maxLongitude: 35.70
    )

    func testFetchesRealVehiclesAndHoldsEveryInvariantTheMapRelesOn() async throws {
        try XCTSkipUnless(isEnabled, "set YALLASA_LIVE_TESTS=1 to run live network tests")

        let source = StrideVehicleSource()
        let vehicles = try await source.vehicles(in: israel, within: 300, limit: 1000)

        print("vehicles returned : \(vehicles.count)")

        // Not a failure on its own. At 03:00, and across most of Israel on
        // Shabbat, nothing is running — the API answering is what matters.
        guard let newest = vehicles.max(by: { $0.recordedAt < $1.recordedAt }) else {
            print("no vehicles reporting right now — endpoint answered, fleet is idle")
            return
        }

        let age = Date().timeIntervalSince(newest.recordedAt)
        print("freshest fix age  : \(Int(age))s")
        print("distinct lines    : \(Set(vehicles.map(\.lineReference)).count)")
        print("moving            : \(vehicles.filter(\.isMoving).count)")

        // One position per vehicle. The API returns a row per SIRI snapshot, so
        // failing this means the map is drawing a smear of markers per bus.
        XCTAssertEqual(
            vehicles.count, Set(vehicles.map(\.id)).count,
            "duplicate vehicle ids survived the reduce"
        )

        XCTAssertLessThanOrEqual(
            age, StrideVehicleSource.maximumUsableAge,
            "freshest fix is older than the usable window — the pipeline may be stalled"
        )

        for vehicle in vehicles {
            XCTAssertTrue(vehicle.point.isValid, "invalid coordinate for \(vehicle.id)")
            XCTAssertFalse(vehicle.lineReference.isEmpty, "empty lineReference for \(vehicle.id)")

            // The endpoint really does serve rows stamped 2038. None may survive.
            XCTAssertLessThan(
                vehicle.recordedAt.timeIntervalSinceNow, 120,
                "a future-stamped fix survived: \(vehicle.recordedAt)"
            )

            // Feeds keep the last heading on a parked vehicle; drawing it points
            // the arrow down whatever road the bus stopped on.
            if !vehicle.isMoving {
                XCTAssertNil(
                    vehicle.bearingDegrees,
                    "stationary vehicle \(vehicle.id) kept a bearing"
                )
            }
        }

        for vehicle in vehicles.prefix(5) {
            let speed = vehicle.speedKilometresPerHour.map { "\(Int($0)) km/h" } ?? "—"
            print("  line \(vehicle.lineReference) at \(vehicle.point.latitude), \(vehicle.point.longitude)  \(speed)")
        }
    }

    /// The bounding box has to filter server-side, or the app downloads the
    /// whole country every twenty seconds to draw a few streets.
    func testBoundingBoxActuallyConstrainsResults() async throws {
        try XCTSkipUnless(isEnabled, "set YALLASA_LIVE_TESTS=1 to run live network tests")

        let source = StrideVehicleSource()
        let local = try await source.vehicles(in: telAviv, within: 300, limit: 1000)

        guard !local.isEmpty else {
            print("nothing reporting in Tel Aviv right now — cannot assert bounds")
            return
        }

        for vehicle in local {
            XCTAssertTrue(
                vehicle.point.latitude >= telAviv.minLatitude - 0.01
                    && vehicle.point.latitude <= telAviv.maxLatitude + 0.01
                    && vehicle.point.longitude >= telAviv.minLongitude - 0.01
                    && vehicle.point.longitude <= telAviv.maxLongitude + 0.01,
                "\(vehicle.id) at \(vehicle.point.latitude),\(vehicle.point.longitude) is outside the requested box"
            )
        }
        print("all \(local.count) vehicles fell inside the requested box")
    }

    /// An empty region must come back empty rather than throwing — the map pans
    /// over the sea and over Jordan constantly.
    func testEmptyRegionReturnsEmptyRatherThanThrowing() async throws {
        try XCTSkipUnless(isEnabled, "set YALLASA_LIVE_TESTS=1 to run live network tests")

        // Open Mediterranean, well off the coast.
        let sea = GeoBounds(
            minLatitude: 32.0, minLongitude: 33.0,
            maxLatitude: 32.2, maxLongitude: 33.2
        )
        let vehicles = try await StrideVehicleSource().vehicles(in: sea, within: 300, limit: 100)
        XCTAssertTrue(vehicles.isEmpty, "found \(vehicles.count) buses at sea")
    }
}
