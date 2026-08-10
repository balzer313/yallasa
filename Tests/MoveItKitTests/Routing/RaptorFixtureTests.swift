import XCTest
@testable import MoveItKit

/// Correctness tests for the journey planner against hand-built networks with
/// known-good answers.
///
/// Every expected time here was worked out by hand from the fixture's timetable,
/// not read off the implementation. That is the point: a router that agrees with
/// itself proves nothing.
final class RaptorFixtureTests: XCTestCase {

    // Stop indices in `twoLineNetwork`.
    private let ashfield: StopIndex = 0
    private let bridgeway: StopIndex = 1
    private let carlton: StopIndex = 2
    private let bridgewayEast: StopIndex = 3
    private let eastgate: StopIndex = 4

    /// Walking is capped tightly in most tests so that the pure-walk option,
    /// which is legitimately Pareto-optimal over these short distances, does not
    /// obscure the transit answer under test.
    private func options(
        maximumTransfers: Int = 4,
        totalWalk: Double = 800
    ) -> PlanOptions {
        var options = PlanOptions()
        options.maximumTransfers = maximumTransfers
        options.maximumTotalWalkMeters = totalWalk
        options.usesRealtime = true
        return options
    }

    private func departAfter(_ seconds: ServiceSeconds, on date: ServiceDate) -> PlanTimeAnchor {
        .departAfter(ServiceInstant(date: date, seconds: seconds))
    }

    // MARK: - Direct journeys

    func testDirectRideTakesTheFirstDepartureAndArrivesOnSchedule() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: departAfter(28_800, on: fixture.defaultDate),   // 08:00
                options: options()
            )
        )

        let best = try XCTUnwrap(result.journeys.first, "expected at least one journey")
        // 08:00 departure, twelve minutes to Carlton.
        XCTAssertEqual(best.departure, 28_800)
        XCTAssertEqual(best.arrival, 29_520)
        XCTAssertEqual(best.transferCount, 0)
        XCTAssertEqual(best.rides.count, 1)
        XCTAssertEqual(best.rides.first?.boardStop, ashfield)
        XCTAssertEqual(best.rides.first?.alightStop, carlton)
    }

    func testLaterDeparturesAreOfferedAsAlternatives() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: options()
            )
        )

        // Three trips leave inside the default one-hour window; each is
        // Pareto-optimal because it departs later and arrives later.
        let departures = Set(result.journeys.map(\.departure))
        XCTAssertTrue(departures.contains(28_800))
        XCTAssertTrue(departures.contains(29_400))
        XCTAssertTrue(departures.contains(30_000))
    }

    func testAskingAfterTheLastDepartureFindsNothing() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        var tight = options()
        tight.searchWindowSeconds = 600

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: departAfter(40_000, on: fixture.defaultDate),   // 11:06
                options: tight
            )
        )
        XCTAssertTrue(result.journeys.isEmpty)
    }

    // MARK: - Transfers

    func testJourneyRequiringAFootpathTransfer() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(eastgate),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: options()
            )
        )

        let best = try XCTUnwrap(result.journeys.first)
        // 08:00 from Ashfield, 08:06 at Bridgeway, two-minute walk, 08:20 from
        // Bridgeway East, 08:28 at Eastgate.
        XCTAssertEqual(best.arrival, 30_480)
        XCTAssertEqual(best.transferCount, 1)
        XCTAssertEqual(best.rides.count, 2)
        XCTAssertEqual(best.rides.first?.alightStop, bridgeway)
        XCTAssertEqual(best.rides.last?.boardStop, bridgewayEast)
        // The walking leg between the two rides must actually be in the journey.
        XCTAssertTrue(best.legs.contains { $0.walkLeg?.origin.stop == bridgeway })
    }

    func testTransferLimitOfZeroExcludesTheTwoLegJourney() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(eastgate),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: options(maximumTransfers: 0)
            )
        )
        XCTAssertTrue(
            result.journeys.allSatisfy { $0.transferCount == 0 },
            "a zero-transfer search must not return a journey that changes vehicle"
        )
        XCTAssertTrue(
            result.journeys.isEmpty,
            "there is no direct service from Ashfield to Eastgate"
        )
    }

    // MARK: - Calendars

    func testTripWhoseServiceIsInactiveOnTheQueryDateIsNotUsed() throws {
        var fixture = GraphFixture.twoLineNetwork()
        // Move every Route 1 trip onto the service that runs only on day 5.
        fixture.trips = fixture.trips.map { trip in
            var trip = trip
            if trip.pattern == 0 { trip.service = 1 }
            return trip
        }
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let onQuietDay = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: departAfter(28_800, on: fixture.calendarStart.adding(days: 2)),
                options: options()
            )
        )
        XCTAssertTrue(onQuietDay.journeys.isEmpty, "route 1 does not run on day 2")

        let onServiceDay = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: departAfter(28_800, on: fixture.calendarStart.adding(days: 5)),
                options: options()
            )
        )
        XCTAssertFalse(onServiceDay.journeys.isEmpty, "route 1 does run on day 5")
    }

    func testDateOutsideTheFeedCalendarThrows() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let farFuture = fixture.calendarStart.adding(days: 400)
        XCTAssertThrowsError(
            try planner.plan(
                PlanRequest(
                    origin: .stop(ashfield),
                    destination: .stop(carlton),
                    anchor: departAfter(28_800, on: farFuture),
                    options: options()
                )
            )
        ) { error in
            XCTAssertEqual(error as? PlanError, .dateNotCovered(farFuture))
        }
    }

    // MARK: - After midnight
    //
    // The single most valuable test in this file. GTFS expresses the 01:10 night
    // bus as the *previous* service day at 25:10, so a query at 00:30 has to look
    // back a service day to find it. Routers that skip that offset work perfectly
    // until half past midnight and then confidently report no service.

    func testQueryAfterMidnightFindsThePreviousServiceDaysLateTrip() throws {
        let fixture = GraphFixture.afterMidnightNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        // 00:30 on day 3. The trip we must find belongs to day 2's service and is
        // stored as 25:10 (90600), i.e. 01:10 in this query's frame.
        let result = try planner.plan(
            PlanRequest(
                origin: .stop(0),
                destination: .stop(1),
                anchor: departAfter(1_800, on: fixture.calendarStart.adding(days: 3)),
                options: options(totalWalk: 200)
            )
        )

        let best = try XCTUnwrap(
            result.journeys.first,
            "the 01:10 night bus must be reachable from a 00:30 query"
        )
        XCTAssertEqual(best.departure, 4_200, "01:10 expressed in the query day's frame")
        XCTAssertEqual(best.arrival, 5_100, "01:25 expressed in the query day's frame")

        // And the leg must be attributed to the service day it actually belongs
        // to, which is the day before the query.
        let ride = try XCTUnwrap(best.rides.first)
        XCTAssertEqual(ride.serviceDate, fixture.calendarStart.adding(days: 2))
    }

    // MARK: - Arrive by

    func testArriveByReturnsTheLatestFeasibleDeparture() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        // Be at Carlton by 08:15. The 08:10 trip arrives 08:22 and is too late;
        // the 08:00 trip arrives 08:12 and is the answer.
        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: .arriveBy(ServiceInstant(date: fixture.defaultDate, seconds: 29_700)),
                options: options()
            )
        )

        let best = try XCTUnwrap(result.journeys.first)
        XCTAssertEqual(best.departure, 28_800)
        XCTAssertEqual(best.arrival, 29_520)
        XCTAssertTrue(
            result.journeys.allSatisfy { $0.arrival <= 29_700 },
            "an arrive-by search must never return a journey that arrives late"
        )
    }

    // MARK: - Realtime

    func testDelayPushingAConnectionOutOfReachSelectsTheLaterTrip() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        // Delay the 08:00 Route 1 trip by fifteen minutes. It now reaches
        // Bridgeway at 08:21, so after the two-minute walk the 08:20 from
        // Bridgeway East is gone and the 08:30 has to be used instead.
        let realtime = StubRealtimeSource()
        let firstRoute1Trip = graph.globalTripIndex(0, offset: 0)
        realtime.setDelay(900, trip: firstRoute1Trip, positions: 3)

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(eastgate),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: options()
            ),
            realtime: realtime
        )

        let delayed = try XCTUnwrap(
            result.journeys.first { $0.rides.first?.trip == firstRoute1Trip },
            "the delayed trip should still be usable, just with a later connection"
        )
        XCTAssertEqual(delayed.arrival, 31_080, "08:30 from Bridgeway East, arriving 08:38")
        XCTAssertEqual(delayed.rides.first?.departureDelay, 900)
    }

    func testCancelledTripIsNotBoarded() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        let realtime = StubRealtimeSource()
        let firstTrip = graph.globalTripIndex(0, offset: 0)
        realtime.cancel(trip: firstTrip, positions: 3)

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: options()
            ),
            realtime: realtime
        )

        XCTAssertFalse(
            result.journeys.contains { $0.rides.contains { $0.trip == firstTrip } },
            "a cancelled trip must never appear in a journey"
        )
        // The 08:10 service is unaffected and should be the new best answer.
        XCTAssertEqual(result.journeys.first?.departure, 29_400)
    }

    // MARK: - Walking

    func testShortHopIsOfferedAsAWalkRatherThanHidden() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        // Bridgeway to Bridgeway East is 110 m apart. Walking is obviously right,
        // and an app that only offered a bus here would be wrong.
        let origin = graph.stopCoordinate(bridgeway)
        let destination = graph.stopCoordinate(bridgewayEast)

        let result = try planner.plan(
            PlanRequest(
                origin: .coordinate(origin),
                destination: .coordinate(destination),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: options()
            )
        )

        XCTAssertTrue(
            result.journeys.contains { $0.isWalkOnly },
            "a two-minute walk must be offered"
        )
    }

    func testWalkingBudgetExcludesJourneysThatWalkTooFar() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        var strict = options()
        strict.maximumTotalWalkMeters = 50   // shorter than the 110 m footpath

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(eastgate),
                anchor: departAfter(28_800, on: fixture.defaultDate),
                options: strict
            )
        )
        XCTAssertTrue(
            result.journeys.isEmpty,
            "the only route needs a 110 m walk, which the budget forbids"
        )
    }

    // MARK: - Endpoint resolution

    func testIdenticalStopEndpointsAreRejected() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        XCTAssertThrowsError(
            try planner.plan(
                PlanRequest(
                    origin: .stop(ashfield),
                    destination: .stop(ashfield),
                    anchor: departAfter(28_800, on: fixture.defaultDate),
                    options: options()
                )
            )
        ) { error in
            XCTAssertEqual(error as? PlanError, .trivialJourney)
        }
    }

    func testCoordinateFarFromAnyStopIsReported() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()
        let planner = JourneyPlanner(graph: graph)

        // Several hundred kilometres away, well beyond the escalating search.
        let middleOfNowhere = GeoPoint(latitude: 20.0, longitude: 20.0)

        XCTAssertThrowsError(
            try planner.plan(
                PlanRequest(
                    origin: .coordinate(middleOfNowhere),
                    destination: .stop(carlton),
                    anchor: departAfter(28_800, on: fixture.defaultDate),
                    options: options()
                )
            )
        ) { error in
            XCTAssertEqual(error as? PlanError, .noStopsNearOrigin)
        }
    }

    // MARK: - Pareto filtering

    func testDominatedJourneysAreRemoved() {
        let base = GraphFixture().calendarStart

        func journey(departure: ServiceSeconds, arrival: ServiceSeconds, rides: Int) -> Journey {
            var legs: [JourneyLeg] = []
            for index in 0..<max(rides, 1) {
                legs.append(
                    .ride(
                        RideLeg(
                            pattern: PatternIndex(index), tripOffset: 0,
                            trip: TripIndex(index), route: 0,
                            boardPosition: 0, alightPosition: 1,
                            boardStop: StopIndex(index), alightStop: StopIndex(index + 1),
                            scheduledDeparture: departure, scheduledArrival: arrival,
                            departureDelay: nil, arrivalDelay: nil, serviceDate: base
                        )
                    )
                )
            }
            return Journey(legs: legs, baseDate: base)
        }

        // B leaves earlier, arrives later and changes more often than A, so it is
        // dominated on every axis and there is no preference that would pick it.
        let a = journey(departure: 1_000, arrival: 2_000, rides: 1)
        let b = journey(departure: 900, arrival: 2_100, rides: 2)
        let kept = JourneyPlanner.paretoFiltered([a, b])

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.departure, 1_000)
    }

    func testNonDominatedTradeOffIsKept() {
        let base = GraphFixture().calendarStart

        func journey(departure: ServiceSeconds, arrival: ServiceSeconds, rides: Int) -> Journey {
            var legs: [JourneyLeg] = []
            for index in 0..<rides {
                legs.append(
                    .ride(
                        RideLeg(
                            pattern: PatternIndex(index), tripOffset: 0,
                            trip: TripIndex(index), route: 0,
                            boardPosition: 0, alightPosition: 1,
                            boardStop: StopIndex(index), alightStop: StopIndex(index + 1),
                            scheduledDeparture: departure, scheduledArrival: arrival,
                            departureDelay: nil, arrivalDelay: nil, serviceDate: base
                        )
                    )
                )
            }
            return Journey(legs: legs, baseDate: base)
        }

        // Faster but with a change, versus slower and direct. A rider might
        // reasonably want either, so both must survive.
        let fast = journey(departure: 1_000, arrival: 1_800, rides: 2)
        let simple = journey(departure: 1_000, arrival: 2_000, rides: 1)
        XCTAssertEqual(JourneyPlanner.paretoFiltered([fast, simple]).count, 2)
    }
}
