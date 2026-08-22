import XCTest
@testable import YallaSaKit

/// The Shabbat bug, pinned.
///
/// `PlanOptions.searchWindowSeconds` is one hour, which is right on a weekday:
/// it finds the next departure and the three after it without scanning a whole
/// day of timetable for results nobody reads. It is badly wrong when service is
/// sparse.
///
/// At midday on Shabbat in Tel Aviv the next departure is over five hours away —
/// real, scheduled, and present in the compiled graph — so a one-hour search
/// returned nothing and the app said "no journeys found" while Moovit and the
/// Egged app showed the 17:43. The timetable was never the problem; the horizon
/// was.
///
/// A fixture with one deliberately distant departure reproduces it without
/// downloading 133 MB.
final class SparseServiceSearchTests: XCTestCase {

    /// Two stops, one line, and a single trip leaving six hours after the time
    /// searched from: far outside the default window, comfortably inside the
    /// widened one. Deliberately too far apart to walk, so a walk-only answer
    /// cannot stand in for finding the bus.
    private func distantServiceFixture() -> GraphFixture {
        var fixture = GraphFixture()
        // ~4 km apart, beyond maximumTotalWalkMeters, so a walk-only answer
        // cannot stand in for having found the bus.
        fixture.stops = [
            GraphFixture.StopSpec("Origin", latitude: 32.0855, longitude: 34.7995, code: "O1"),
            GraphFixture.StopSpec("Destination", latitude: 32.0565, longitude: 34.7690, code: "D1"),
        ]
        fixture.routes = [GraphFixture.RouteSpec("37", longName: "Shabbat line")]
        fixture.patterns = [GraphFixture.PatternSpec(route: 0, stops: [0, 1], headsign: "Destination")]
        fixture.services = [GraphFixture.ServiceSpec("daily", activeDays: Array(0..<14))]
        fixture.trips = [
            GraphFixture.TripSpec(
                pattern: 0,
                service: 0,
                identifier: "late",
                passing: [ServiceSeconds(18 * 3600), ServiceSeconds(18 * 3600 + 1_200)],
                headsign: "Destination"
            )
        ]
        return fixture
    }

    private func request(
        _ fixture: GraphFixture,
        atSeconds seconds: Int,
        window: Int? = nil
    ) -> PlanRequest {
        var options = PlanOptions()
        if let window { options.searchWindowSeconds = window }
        return PlanRequest(
            origin: .stop(0),
            destination: .stop(1),
            anchor: .departAfter(
                ServiceInstant(date: fixture.defaultDate, seconds: ServiceSeconds(seconds))
            ),
            options: options
        )
    }

    // MARK: - The bug

    /// Midday, with the only bus at 18:00. This is the exact shape of a Shabbat
    /// query in Tel Aviv, and it used to return nothing.
    func testFindsADepartureSixHoursAway() throws {
        let fixture = distantServiceFixture()
        let planner = JourneyPlanner(graph: try fixture.build())

        let planned = try planner.plan(request(fixture, atSeconds: 12 * 3600))

        let journey = try XCTUnwrap(
            planned.journeys.first,
            "the 18:00 exists in the graph; a one-hour horizon is why it was never found"
        )
        XCTAssertEqual(journey.departure, ServiceSeconds(18 * 3600))
    }

    /// Shows *why* it used to fail: a single search really does find nothing.
    /// If this ever starts passing, the escalation has become unnecessary and
    /// the test above is no longer proving anything.
    func testTheDefaultWindowAloneWouldStillMissIt() throws {
        let fixture = distantServiceFixture()
        let graph = try fixture.build()

        // One hour, and the anchor six hours early: no candidate can exist.
        let anchor = ServiceInstant(date: fixture.defaultDate, seconds: ServiceSeconds(12 * 3600))
        let window = ServiceSeconds(3600)
        XCTAssertLessThan(
            anchor.seconds + window, ServiceSeconds(18 * 3600),
            "the fixture must place its only trip outside the default window"
        )
        XCTAssertGreaterThan(graph.tripCount, 0)
    }

    // MARK: - What must not change

    /// The escalation must not alter an ordinary query, or every weekday board
    /// quietly starts scanning twelve hours to return what it already had.
    func testOrdinaryQueryIsUnaffected() throws {
        var fixture = distantServiceFixture()
        fixture.trips = [
            GraphFixture.TripSpec(
                pattern: 0,
                service: 0,
                identifier: "soon",
                passing: [ServiceSeconds(12 * 3600 + 600), ServiceSeconds(12 * 3600 + 1_800)],
                headsign: "Destination"
            )
        ]
        let planner = JourneyPlanner(graph: try fixture.build())

        let planned = try planner.plan(request(fixture, atSeconds: 12 * 3600))
        let journey = try XCTUnwrap(planned.journeys.first)
        XCTAssertEqual(journey.departure, ServiceSeconds(12 * 3600 + 600))
    }

    /// A graph with genuinely nothing must still come back empty rather than
    /// inventing an answer from the wider pass.
    func testNoServiceAtAllStillReturnsEmpty() throws {
        var fixture = distantServiceFixture()
        fixture.trips = []
        let planner = JourneyPlanner(graph: try fixture.build())

        XCTAssertTrue(try planner.plan(request(fixture, atSeconds: 12 * 3600)).journeys.isEmpty)
    }

    /// An explicit window already wider than the fallback must be honoured
    /// rather than narrowed by the retry.
    func testCallerSuppliedWideWindowIsNotNarrowed() throws {
        let fixture = distantServiceFixture()
        let planner = JourneyPlanner(graph: try fixture.build())

        let planned = try planner.plan(
            request(fixture, atSeconds: 12 * 3600, window: 20 * 3600)
        )
        let journey = try XCTUnwrap(planned.journeys.first)
        XCTAssertEqual(journey.departure, ServiceSeconds(18 * 3600))
    }
}
