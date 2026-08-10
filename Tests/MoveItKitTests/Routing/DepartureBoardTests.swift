import XCTest
@testable import MoveItKit

final class DepartureBoardTests: XCTestCase {

    private let ashfield: StopIndex = 0
    private let bridgeway: StopIndex = 1
    private let carlton: StopIndex = 2

    private func board(_ fixture: GraphFixture) throws -> (TransitGraph, DepartureBoardService) {
        let graph = try fixture.build()
        return (graph, DepartureBoardService(graph: graph))
    }

    func testUpcomingDeparturesAreReturnedInTimeOrder() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (_, service) = try board(fixture)

        let departures = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: EmptyRealtimeSource.shared
        )

        XCTAssertEqual(departures.map(\.scheduledDeparture), [28_800, 29_400, 30_000])
        XCTAssertTrue(departures.allSatisfy { $0.stop == self.ashfield })
        XCTAssertTrue(departures.allSatisfy { $0.delay == nil }, "no realtime means no delay, not a zero delay")
    }

    func testWindowExcludesDeparturesBeyondIt() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (_, service) = try board(fixture)

        let departures = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 500,      // the 08:10 departure is 600 s away
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertEqual(departures.map(\.scheduledDeparture), [28_800])
    }

    func testPerPatternLimitKeepsABusyStopReadable() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (_, service) = try board(fixture)

        let departures = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 1,
            modes: nil,
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertEqual(departures.count, 1)
        XCTAssertEqual(departures.first?.scheduledDeparture, 28_800)
    }

    func testFinalStopOfAPatternIsNotADeparture() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (_, service) = try board(fixture)

        // Carlton is where Route 1 terminates. Nothing departs from it.
        let departures = service.departures(
            from: [carlton],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertTrue(departures.isEmpty)
    }

    func testModeFilterExcludesOtherModes() throws {
        var fixture = GraphFixture.twoLineNetwork()
        fixture.routes[0].routeType = 3     // bus
        fixture.routes[1].routeType = 2     // rail
        let (_, service) = try board(fixture)

        let railOnly = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: [.rail],
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertTrue(railOnly.isEmpty, "only the bus route serves Ashfield")

        let busOnly = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: [.bus],
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertEqual(busOnly.count, 3)
    }

    func testRealtimeDelayMovesADepartureAndIsReported() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (graph, service) = try board(fixture)

        let realtime = StubRealtimeSource()
        // Fifteen minutes, chosen so the 08:00 bus actually falls behind the 08:10
        // one. A smaller delay would still leave the board in schedule order and
        // the test would pass without proving anything.
        realtime.setDelay(900, trip: graph.globalTripIndex(0, offset: 0), positions: 3)

        let departures = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: realtime
        )

        let delayed = try XCTUnwrap(departures.first { $0.scheduledDeparture == 28_800 })
        XCTAssertEqual(delayed.delay, 900)
        XCTAssertEqual(delayed.actualDeparture, 29_700)

        // The board is ordered by when the vehicle actually goes, not by the
        // timetable — so the delayed 08:00 now sits behind the 08:10.
        XCTAssertEqual(departures.map(\.actualDeparture), [29_400, 29_700, 30_000])
        XCTAssertEqual(departures.first?.scheduledDeparture, 29_400)
    }

    func testCancelledDepartureIsStillShownSoRidersKnowItIsNotComing() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (graph, service) = try board(fixture)

        let realtime = StubRealtimeSource()
        let cancelledTrip = graph.globalTripIndex(0, offset: 0)
        realtime.cancel(trip: cancelledTrip, positions: 3)

        let departures = service.departures(
            from: [ashfield],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 28_800),
            withinSeconds: 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: realtime
        )

        let cancelled = try XCTUnwrap(departures.first { $0.trip == cancelledTrip })
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertEqual(departures.count, 3, "a cancellation removes a bus, not a row")
    }

    // MARK: - After midnight

    func testBoardAtHalfPastMidnightFindsThePreviousServiceDaysTrip() throws {
        let fixture = GraphFixture.afterMidnightNetwork()
        let (_, service) = try board(fixture)

        let queryDate = fixture.calendarStart.adding(days: 3)
        let departures = service.departures(
            from: [0],
            after: ServiceInstant(date: queryDate, seconds: 1_800),   // 00:30
            withinSeconds: 3 * 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: EmptyRealtimeSource.shared
        )

        XCTAssertEqual(
            departures.map(\.scheduledDeparture), [4_200],
            "the 25:10 trip of the previous service day is 01:10 today"
        )
        XCTAssertEqual(
            departures.first?.serviceDate, fixture.calendarStart.adding(days: 2),
            "it must be attributed to the service day it belongs to"
        )
    }

    func testEveningBoardSeesBothTonightsTrips() throws {
        let fixture = GraphFixture.afterMidnightNetwork()
        let (_, service) = try board(fixture)

        // 23:00 with a six-hour window spans midnight and must pick up both the
        // 23:40 and the 25:10 (01:10) departures of the same service day.
        let departures = service.departures(
            from: [0],
            after: ServiceInstant(date: fixture.defaultDate, seconds: 82_800),
            withinSeconds: 6 * 3_600,
            limit: 20,
            limitPerPattern: 10,
            modes: nil,
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertEqual(departures.map(\.scheduledDeparture), [85_200, 90_600])
    }

    // MARK: - Timetables

    func testPatternTimetableListsEveryTripOfThatServiceDay() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let (_, service) = try board(fixture)

        let timetable = service.departures(
            pattern: 0,
            at: 0,
            on: fixture.defaultDate,
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertEqual(timetable.map(\.scheduledDeparture), [28_800, 29_400, 30_000])
    }

    func testPatternTimetableIsEmptyOnADayTheServiceDoesNotRun() throws {
        var fixture = GraphFixture.twoLineNetwork()
        fixture.trips = fixture.trips.map { trip in
            var trip = trip
            if trip.pattern == 0 { trip.service = 1 }   // day 5 only
            return trip
        }
        let (_, service) = try board(fixture)

        let quiet = service.departures(
            pattern: 0, at: 0,
            on: fixture.calendarStart.adding(days: 2),
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertTrue(quiet.isEmpty)

        let busy = service.departures(
            pattern: 0, at: 0,
            on: fixture.calendarStart.adding(days: 5),
            realtime: EmptyRealtimeSource.shared
        )
        XCTAssertEqual(busy.count, 3)
    }

    // MARK: - Graph plumbing
    //
    // These assert the fixture and the reader agree, which everything above
    // silently depends on.

    func testFixtureRoundTripsThroughTheBinaryFormat() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()

        XCTAssertEqual(graph.stopCount, 5)
        XCTAssertEqual(graph.patternCount, 2)
        XCTAssertEqual(graph.tripCount, 6)
        XCTAssertEqual(graph.routeCount, 2)
        XCTAssertEqual(graph.stopName(0), "Ashfield")
        XCTAssertEqual(graph.routeDisplayName(0), "1")

        // Stop-time addressing is the arithmetic most likely to be wrong.
        XCTAssertEqual(graph.departureTime(pattern: 0, tripOffset: 0, position: 0), 28_800)
        XCTAssertEqual(graph.arrivalTime(pattern: 0, tripOffset: 0, position: 2), 29_520)
        XCTAssertEqual(graph.departureTime(pattern: 0, tripOffset: 2, position: 0), 30_000)
        XCTAssertEqual(graph.departureTime(pattern: 1, tripOffset: 0, position: 0), 30_000)

        // CSR adjacency.
        let patternsAtBridgeway = graph.patterns(atStop: bridgeway)
        XCTAssertEqual(patternsAtBridgeway.count, 1)
        XCTAssertEqual(patternsAtBridgeway.first?.pattern, 0)
        XCTAssertEqual(patternsAtBridgeway.first?.position, 1)

        let transfers = graph.transfers(fromStop: bridgeway)
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(transfers.first?.target, 3)
        XCTAssertEqual(transfers.first?.seconds, 120)

        // Boarding rules.
        XCTAssertTrue(graph.patternAllowsBoarding(0, at: 0))
        XCTAssertFalse(graph.patternAllowsBoarding(0, at: 2), "cannot board at a terminus")
        XCTAssertFalse(graph.patternAllowsAlighting(0, at: 0), "cannot alight where you got on")
    }

    func testCalendarBitsetsSurviveTheRoundTrip() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()

        let dailyService: ServiceIndex = 0
        let day5Service: ServiceIndex = 1

        XCTAssertTrue(graph.isServiceActive(dailyService, dayIndex: 2))
        XCTAssertTrue(graph.isServiceActive(dailyService, dayIndex: 13))
        XCTAssertFalse(graph.isServiceActive(day5Service, dayIndex: 2))
        XCTAssertTrue(graph.isServiceActive(day5Service, dayIndex: 5))

        XCTAssertEqual(graph.dayIndex(for: fixture.calendarStart), 0)
        XCTAssertEqual(graph.dayIndex(for: fixture.calendarStart.adding(days: 5)), 5)
        XCTAssertNil(graph.dayIndex(for: fixture.calendarStart.adding(days: 99)))
    }

    func testSpatialGridFindsNearbyStops() throws {
        let fixture = GraphFixture.twoLineNetwork()
        let graph = try fixture.build()

        // Bridgeway and Bridgeway East are ~110 m apart; nothing else is close.
        let nearby = graph.stops(near: graph.stopCoordinate(bridgeway), radiusMeters: 300, limit: 10)
        let found = Set(nearby.map(\.stop))
        XCTAssertTrue(found.contains(bridgeway))
        XCTAssertTrue(found.contains(3))
        XCTAssertFalse(found.contains(ashfield), "Ashfield is roughly 800 m away")

        // Sorted nearest-first, which the departures board relies on.
        XCTAssertEqual(nearby.map(\.distanceMeters), nearby.map(\.distanceMeters).sorted())
    }
}
