import XCTest
@testable import MoveItKit

final class PatternBuilderTests: XCTestCase {

    private let stops: [StopIndex] = [10, 11, 12]
    private let regular: [UInt8] = [0, 0, 0]

    /// A trip whose times are `base`, `base + 300`, `base + 600` with a 30 s dwell.
    private func addTrip(
        _ builder: PatternBuilder,
        sourceTrip: TripIndex,
        base: ServiceSeconds,
        stops: [StopIndex]? = nil,
        pickups: [UInt8]? = nil,
        dropOffs: [UInt8]? = nil,
        arrivals: [ServiceSeconds]? = nil
    ) {
        let stopList = stops ?? self.stops
        let times = arrivals ?? [base, base + 300, base + 600]
        builder.add(
            sourceTrip: sourceTrip,
            route: 1,
            stops: stopList,
            pickups: pickups ?? regular,
            dropOffs: dropOffs ?? regular,
            arrivals: times,
            departures: times.map { $0 + 30 }
        )
    }

    func testIdenticalSequencesShareOnePattern() {
        let builder = PatternBuilder()
        addTrip(builder, sourceTrip: 0, base: 28_800)
        addTrip(builder, sourceTrip: 1, base: 32_400)
        let result = builder.finish()

        XCTAssertEqual(result.patterns.count, 1)
        XCTAssertEqual(result.overtakingSplits, 0)
        XCTAssertEqual(result.patterns[0].stops, stops)
        XCTAssertEqual(result.patterns[0].sourceTrips, [0, 1])
        XCTAssertEqual(result.patterns[0].arrivals.count, 6)
    }

    func testTripsAreSortedByFirstDeparture() {
        let builder = PatternBuilder()
        addTrip(builder, sourceTrip: 0, base: 50_000)
        addTrip(builder, sourceTrip: 1, base: 10_000)
        addTrip(builder, sourceTrip: 2, base: 30_000)
        let result = builder.finish()

        XCTAssertEqual(result.patterns.count, 1)
        let pattern = result.patterns[0]
        XCTAssertEqual(pattern.sourceTrips, [1, 2, 0])
        XCTAssertEqual(pattern.departures[0], 10_030)
        XCTAssertEqual(pattern.departures[3], 30_030)
        XCTAssertEqual(pattern.departures[6], 50_030)
    }

    func testDifferentStopSequenceSplitsPatterns() {
        let builder = PatternBuilder()
        addTrip(builder, sourceTrip: 0, base: 10_000)
        addTrip(builder, sourceTrip: 1, base: 20_000, stops: [10, 11, 13])
        let result = builder.finish()

        XCTAssertEqual(result.patterns.count, 2)
        XCTAssertEqual(result.overtakingSplits, 0, "A different stop list is not an overtaking split")
    }

    func testDifferentPickupOrDropOffSplitsPatterns() {
        let builder = PatternBuilder()
        addTrip(builder, sourceTrip: 0, base: 10_000)
        // Same stops, but the middle stop is drop-off only on the second trip.
        addTrip(builder, sourceTrip: 1, base: 20_000, pickups: [0, 1, 0])
        addTrip(builder, sourceTrip: 2, base: 30_000, dropOffs: [0, 1, 0])
        let result = builder.finish()

        XCTAssertEqual(result.patterns.count, 3)
    }

    func testOvertakingSplitsIntoTwoPatterns() {
        let builder = PatternBuilder()
        // The local leaves first and dawdles; the express leaves later and passes
        // it before the last stop.
        addTrip(builder, sourceTrip: 0, base: 10_000, arrivals: [10_000, 11_500, 13_000])
        addTrip(builder, sourceTrip: 1, base: 10_600, arrivals: [10_600, 10_900, 11_200])
        let result = builder.finish()

        XCTAssertEqual(result.patterns.count, 2)
        XCTAssertEqual(result.overtakingSplits, 1)

        // Each bucket must be internally ordered at every position.
        for pattern in result.patterns {
            let positions = pattern.stops.count
            for offset in 1..<max(1, pattern.sourceTrips.count) {
                for position in 0..<positions {
                    XCTAssertGreaterThanOrEqual(
                        pattern.departures[offset * positions + position],
                        pattern.departures[(offset - 1) * positions + position]
                    )
                }
            }
        }
    }

    func testNonOvertakingTripsStayTogetherEvenWhenClose() {
        let builder = PatternBuilder()
        addTrip(builder, sourceTrip: 0, base: 10_000, arrivals: [10_000, 10_300, 10_600])
        addTrip(builder, sourceTrip: 1, base: 10_060, arrivals: [10_060, 10_360, 10_660])
        let result = builder.finish()

        XCTAssertEqual(result.patterns.count, 1)
        XCTAssertEqual(result.overtakingSplits, 0)
    }

    func testThreeWayOvertakingProducesOrderedBuckets() {
        let builder = PatternBuilder()
        addTrip(builder, sourceTrip: 0, base: 0, arrivals: [1_000, 4_000, 7_000])
        addTrip(builder, sourceTrip: 1, base: 0, arrivals: [1_100, 3_000, 5_000])
        addTrip(builder, sourceTrip: 2, base: 0, arrivals: [1_200, 4_500, 7_500])
        let result = builder.finish()

        // Trip 1 overtakes trip 0, so it opens a second bucket; trip 2 trails
        // trip 0 everywhere and rejoins the first.
        XCTAssertEqual(result.patterns.count, 2)
        XCTAssertEqual(result.overtakingSplits, 1)
        let bucketed = result.patterns.map { $0.sourceTrips }
        XCTAssertTrue(bucketed.contains([0, 2]), "Got \(bucketed)")
        XCTAssertTrue(bucketed.contains([1]), "Got \(bucketed)")
    }

    func testTooShortTripIsIgnored() {
        let builder = PatternBuilder()
        builder.add(
            sourceTrip: 0,
            route: 1,
            stops: [10],
            pickups: [0],
            dropOffs: [0],
            arrivals: [100],
            departures: [100]
        )
        XCTAssertTrue(builder.isEmpty)
        XCTAssertTrue(builder.finish().patterns.isEmpty)
    }
}
