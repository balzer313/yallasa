import XCTest
@testable import YallaSaKit

final class TransferBuilderTests: XCTestCase {

    /// One degree of latitude is 111,194.9 m under `approximateDistance`, so this
    /// converts a metre offset into the latitude the builder will measure back.
    private func latitude(metersNorth meters: Double) -> Double {
        meters / (GeoPoint.earthRadiusMeters * .pi / 180)
    }

    private func point(metersNorth meters: Double) -> GeoPoint {
        GeoPoint(latitude: latitude(metersNorth: meters), longitude: 0)
    }

    private func targets(_ result: TransferBuilder.Result, from stop: Int) -> [Int32] {
        let start = Int(result.starts[stop])
        let end = start + Int(result.counts[stop])
        guard start <= end, end <= result.targets.count else { return [] }
        return Array(result.targets[start..<end])
    }

    private func seconds(_ result: TransferBuilder.Result, from stop: Int, to target: Int32) -> Int32? {
        let start = Int(result.starts[stop])
        let end = start + Int(result.counts[stop])
        guard start <= end, end <= result.targets.count else { return nil }
        for slot in start..<end where result.targets[slot] == target {
            return result.seconds[slot]
        }
        return nil
    }

    private func meters(_ result: TransferBuilder.Result, from stop: Int, to target: Int32) -> Int32? {
        let start = Int(result.starts[stop])
        let end = start + Int(result.counts[stop])
        guard start <= end, end <= result.targets.count else { return nil }
        for slot in start..<end where result.targets[slot] == target {
            return result.meters[slot]
        }
        return nil
    }

    private func build(
        _ coordinates: [GeoPoint],
        isStation: [Bool]? = nil,
        parents: [StopIndex]? = nil,
        seeds: [TransferBuilder.Seed] = [],
        options: GraphMetadata.BuildOptions = GraphMetadata.BuildOptions()
    ) -> TransferBuilder.Result {
        TransferBuilder.build(
            coordinates: coordinates,
            isStation: isStation ?? [Bool](repeating: false, count: coordinates.count),
            parents: parents ?? [StopIndex](repeating: noIndex, count: coordinates.count),
            seeds: seeds,
            options: options
        )
    }

    func testProximityFootpathsAreGeneratedBothWays() {
        let result = build([point(metersNorth: 0), point(metersNorth: 200)])

        XCTAssertEqual(targets(result, from: 0), [1])
        XCTAssertEqual(targets(result, from: 1), [0])
        // 200 m at 1.33 m/s with a 1.35 detour factor.
        XCTAssertEqual(seconds(result, from: 0, to: 1), 203)
        XCTAssertEqual(meters(result, from: 0, to: 1), 200)
    }

    func testStopsBeyondTheRadiusAreNotConnectedDirectly() {
        var options = GraphMetadata.BuildOptions()
        // Wide enough for one 400 m hop (406 s at 1.33 m/s with the 1.35 detour
        // factor), too tight for two of them chained by the closure (812 s).
        // The cap applies to every footpath, generated or closed — 300 s would
        // also have thrown away the direct edge this test asserts.
        options.maxTransferSeconds = 500
        let result = build(
            [point(metersNorth: 0), point(metersNorth: 400), point(metersNorth: 800)],
            options: options
        )

        XCTAssertEqual(targets(result, from: 0), [1])
        XCTAssertNil(seconds(result, from: 0, to: 2))
    }

    func testTransitiveClosureConnectsThroughAnIntermediateStop() {
        let result = build([point(metersNorth: 0), point(metersNorth: 400), point(metersNorth: 800)])

        // 800 m exceeds the 750 m generation radius, so this edge can only exist
        // because the closure walked through stop 1.
        XCTAssertEqual(Set(targets(result, from: 0)), Set([1, 2]))
        XCTAssertEqual(seconds(result, from: 0, to: 1), 406)
        XCTAssertEqual(seconds(result, from: 0, to: 2), 812)
        XCTAssertEqual(meters(result, from: 0, to: 2), 800)
        XCTAssertEqual(Set(targets(result, from: 2)), Set([0, 1]))
    }

    func testOutDegreeIsCappedAtTheNearest() {
        // Forty stops five metres apart: everything is mutually reachable, so the
        // cap is the only thing keeping the lists short.
        let coordinates = (0..<40).map { point(metersNorth: Double($0) * 5) }
        let result = build(coordinates)

        for stop in 0..<coordinates.count {
            XCTAssertLessThanOrEqual(Int(result.counts[stop]), TransferBuilder.maximumOutDegree)
        }
        XCTAssertEqual(Int(result.counts[0]), TransferBuilder.maximumOutDegree)

        // Kept nearest-first: stop 0's list must not contain a stop further away
        // than one it excluded.
        let kept = Set(targets(result, from: 0))
        XCTAssertTrue(kept.contains(1))
        XCTAssertFalse(kept.contains(39))
    }

    func testForbiddenTransfersAreExcludedInBothTheDirectAndClosedGraph() {
        let seeds = [TransferBuilder.Seed(from: 0, to: 2, seconds: -1, isForbidden: true)]
        let result = build(
            [point(metersNorth: 0), point(metersNorth: 400), point(metersNorth: 800)],
            seeds: seeds
        )

        XCTAssertEqual(targets(result, from: 0), [1], "0→2 is forbidden, even via stop 1")
        XCTAssertNil(seconds(result, from: 0, to: 2))
        // transfer_type 3 is directional; the reverse move is still allowed.
        XCTAssertNotNil(seconds(result, from: 2, to: 0))
        XCTAssertEqual(result.forbiddenPairs, 1)
    }

    func testNoSelfTransfersAreEverEmitted() {
        var coordinates = (0..<12).map { point(metersNorth: Double($0) * 20) }
        // Two stops at exactly the same place, which is where a naive builder
        // produces a zero-length self loop.
        coordinates.append(coordinates[3])
        let seeds = [TransferBuilder.Seed(from: 4, to: 4, seconds: 60, isForbidden: false)]
        let result = build(coordinates, seeds: seeds)

        for stop in 0..<coordinates.count {
            for target in targets(result, from: stop) {
                XCTAssertNotEqual(Int(target), stop)
            }
        }
    }

    func testDeclaredMinimumIsNeverUndercutByAShortcut() {
        let seeds = [TransferBuilder.Seed(from: 0, to: 2, seconds: 900, isForbidden: false)]
        let result = build(
            [point(metersNorth: 0), point(metersNorth: 400), point(metersNorth: 800)],
            seeds: seeds
        )

        // Walking via stop 1 would be 812 s, but the agency says 900.
        XCTAssertEqual(seconds(result, from: 0, to: 2), 900)
    }

    func testChildrenOfOneStationAlwaysGetAMutualTransfer() {
        // The platforms are 800 m apart — past the generation radius — so only the
        // sibling rule can connect them.
        let coordinates = [point(metersNorth: 400), point(metersNorth: 0), point(metersNorth: 800)]
        let result = build(
            coordinates,
            isStation: [true, false, false],
            parents: [noIndex, 0, 0]
        )

        XCTAssertNotNil(seconds(result, from: 1, to: 2))
        XCTAssertNotNil(seconds(result, from: 2, to: 1))
        XCTAssertEqual(Int(result.counts[0]), 0, "A station is never a footpath endpoint of its own")
    }
}
