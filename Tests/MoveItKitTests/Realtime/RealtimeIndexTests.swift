import XCTest
@testable import MoveItKit

/// A four-stop, two-trip graph written through the real `TransitGraphWriter` and
/// read back through the real `TransitGraph`.
///
/// Deliberately not a mock: the whole job of `RealtimeIndex` is to agree with the
/// graph's addressing — patterns, trip offsets, stop-time indices — and a stubbed
/// graph would let a wrong answer look right. Named for this file so it cannot
/// collide with the shared fixture in `Tests/MoveItKitTests/Support`.
enum RealtimeFixture {
    static let stopIdentifiers = ["S1", "S2", "S3", "S4"]
    static let tripIdentifiers = ["T1", "T2"]
    static let routeIdentifier = "R1"
    static let timeZone = TimeZone(identifier: "UTC") ?? .gmt
    static let serviceDay = ServiceDate(year: 2026, month: 8, day: 5)

    static let stopCount = 4
    static let tripCount = 2

    /// Departure of trip `t` at position `p`. Arrivals are 30 seconds earlier
    /// everywhere but the first stop, so a test that confuses the two fails.
    static func scheduledDeparture(trip: Int, position: Int) -> Int32 {
        Int32(28_800 + trip * 3_600 + position * 300)
    }

    static func scheduledArrival(trip: Int, position: Int) -> Int32 {
        position == 0 ? scheduledDeparture(trip: trip, position: position)
                      : scheduledDeparture(trip: trip, position: position) - 30
    }

    static func makeGraph() throws -> TransitGraph {
        var strings = StringTableBuilder()

        var stopNameRefs: [UInt32] = []
        var stopIdentifierRefs: [UInt32] = []
        for identifier in stopIdentifiers {
            stopNameRefs.append(strings.intern("Stop \(identifier)"))
            stopIdentifierRefs.append(strings.intern(identifier))
        }

        var tripIdentifierRefs: [UInt32] = []
        for identifier in tripIdentifiers {
            tripIdentifierRefs.append(strings.intern(identifier))
        }

        let routeIdentifierRef = strings.intern(routeIdentifier)
        let routeShortNameRef = strings.intern("1")
        let routeLongNameRef = strings.intern("Line One")
        let agencyNameRef = strings.intern("Test Agency")
        let agencyIdentifierRef = strings.intern("A1")
        let agencyTimeZoneRef = strings.intern(timeZone.identifier)
        let serviceIdentifierRef = strings.intern("SVC")
        let headsignRef = strings.intern("Stop S4")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moveit-realtime-fixture-\(UUID().uuidString).mvtg")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try TransitGraphWriter(url: url)

        try writer.appendBytes(.stringBlob, strings.finish())

        // Stops
        try writer.append(.stopLatitudeE6, [Int32](repeating: 32_085_300, count: stopCount))
        try writer.append(.stopLongitudeE6, [Int32](repeating: 34_781_800, count: stopCount))
        try writer.append(.stopName, stopNameRefs)
        try writer.append(.stopCode, [UInt32](repeating: 0, count: stopCount))
        try writer.append(.stopIdentifier, stopIdentifierRefs)
        try writer.append(.stopPlatformCode, [UInt32](repeating: 0, count: stopCount))
        try writer.append(.stopParent, [Int32](repeating: noIndex, count: stopCount))
        try writer.append(.stopFlags, [UInt8](repeating: 0, count: stopCount))
        try writer.append(.stopPatternStart, [UInt32]([0, 1, 2, 3]))
        try writer.append(.stopPatternCount, [UInt32](repeating: 1, count: stopCount))
        try writer.append(.stopTransferStart, [UInt32](repeating: 0, count: stopCount))
        try writer.append(.stopTransferCount, [UInt32](repeating: 0, count: stopCount))
        try writer.append(.stopPatternReference, [Int32](repeating: 0, count: stopCount))
        try writer.append(.stopPatternPosition, [UInt16]([0, 1, 2, 3]))

        // One pattern over all four stops.
        try writer.append(.patternRoute, [Int32]([0]))
        try writer.append(.patternStopStart, [UInt32]([0]))
        try writer.append(.patternStopCount, [UInt32]([UInt32(stopCount)]))
        try writer.append(.patternTripStart, [UInt32]([0]))
        try writer.append(.patternTripCount, [UInt32]([UInt32(tripCount)]))
        try writer.append(.patternStopTimeStart, [UInt32]([0]))
        try writer.append(.patternHeadsign, [UInt32]([headsignRef]))
        try writer.append(.patternDirection, [UInt8]([0]))
        try writer.append(.patternFlags, [UInt8]([0]))
        try writer.append(.patternStopReference, [Int32]([0, 1, 2, 3]))
        try writer.append(.patternPickup, [UInt8](repeating: 0, count: stopCount))
        try writer.append(.patternDropOff, [UInt8](repeating: 0, count: stopCount))
        try writer.append(.patternStopDistance, [Int32]([0, 500, 1000, 1500]))

        // Trips
        try writer.append(.tripService, [Int32](repeating: 0, count: tripCount))
        try writer.append(.tripIdentifier, tripIdentifierRefs)
        try writer.append(.tripHeadsign, [UInt32](repeating: headsignRef, count: tripCount))
        try writer.append(.tripShortName, [UInt32](repeating: 0, count: tripCount))
        try writer.append(.tripFlags, [UInt8](repeating: 0, count: tripCount))

        // Stop times, grouped by trip then position.
        var arrivals: [Int32] = []
        var departures: [Int32] = []
        for trip in 0..<tripCount {
            for position in 0..<stopCount {
                arrivals.append(scheduledArrival(trip: trip, position: position))
                departures.append(scheduledDeparture(trip: trip, position: position))
            }
        }
        try writer.append(.stopTimeArrival, arrivals)
        try writer.append(.stopTimeDeparture, departures)

        // Routes
        try writer.append(.routeShortName, [UInt32]([routeShortNameRef]))
        try writer.append(.routeLongName, [UInt32]([routeLongNameRef]))
        try writer.append(.routeIdentifier, [UInt32]([routeIdentifierRef]))
        try writer.append(.routeDescription, [UInt32]([0]))
        try writer.append(.routeType, [UInt16]([3]))
        try writer.append(.routeColor, [UInt32]([UInt32.max]))
        try writer.append(.routeTextColor, [UInt32]([UInt32.max]))
        try writer.append(.routeAgency, [Int32]([0]))

        // Agencies
        try writer.append(.agencyName, [UInt32]([agencyNameRef]))
        try writer.append(.agencyIdentifier, [UInt32]([agencyIdentifierRef]))
        try writer.append(.agencyURL, [UInt32]([0]))
        try writer.append(.agencyTimeZone, [UInt32]([agencyTimeZoneRef]))

        // Calendar: one service, active every day of August 2026.
        try writer.append(.serviceBits, [UInt8](repeating: 0xFF, count: 4))
        try writer.append(.serviceIdentifier, [UInt32]([serviceIdentifierRef]))

        var metadata = GraphMetadata()
        metadata.feedIdentifier = "fixture"
        metadata.feedName = "Realtime Fixture"
        metadata.timeZoneIdentifier = timeZone.identifier
        metadata.calendarStart = ServiceDate(year: 2026, month: 8, day: 1)
        metadata.calendarDayCount = 31
        metadata.serviceBitsetStride = 4
        metadata.counts.stops = stopCount
        metadata.counts.patterns = 1
        metadata.counts.trips = tripCount
        metadata.counts.stopTimes = arrivals.count
        metadata.counts.routes = 1
        metadata.counts.agencies = 1
        metadata.counts.services = 1
        metadata.counts.transfers = 0
        metadata.grid = .empty

        try writer.finish(metadata: metadata)

        // Read the bytes back rather than mapping, so the temporary file can go
        // away immediately and the test leaves nothing behind.
        let data = try Data(contentsOf: url)
        return try TransitGraph.open(data: data)
    }
}

final class RealtimeIndexTests: XCTestCase {

    private var graph: TransitGraph!
    private var lookup: RealtimeTripLookup!

    override func setUpWithError() throws {
        try super.setUpWithError()
        graph = try RealtimeFixture.makeGraph()
        lookup = RealtimeTripLookup(graph: graph)
    }

    override func tearDown() {
        lookup = nil
        graph = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeIndex(
        _ updates: [RTTripUpdate],
        alerts: [RTAlert] = [],
        generatedAt: Date = Date()
    ) -> RealtimeIndex {
        let feed = GTFSRealtimeFeed(
            generatedAt: generatedAt,
            tripUpdates: updates,
            vehiclePositions: [],
            alerts: alerts
        )
        return RealtimeIndex(
            feed: feed,
            graph: graph,
            referenceDate: RealtimeFixture.serviceDay,
            lookup: lookup
        )
    }

    private func update(
        tripID: String = "T1",
        relationship: RTScheduleRelationship? = nil,
        tripDelay: Int32? = nil,
        stops: [RTStopTimeUpdate] = []
    ) -> RTTripUpdate {
        RTTripUpdate(
            entityID: "e-\(tripID)",
            trip: RTTripDescriptor(
                tripID: tripID,
                routeID: RealtimeFixture.routeIdentifier,
                startDate: RealtimeFixture.serviceDay,
                scheduleRelationship: relationship
            ),
            stopTimeUpdates: stops,
            delay: tripDelay
        )
    }

    /// Departure delay at each position, or nil where the snapshot has no data.
    private func departureDelays(_ index: RealtimeIndex, trip: TripIndex = 0) -> [Int32?] {
        (0..<RealtimeFixture.stopCount).map { index.adjustment(trip: trip, position: $0)?.departureDelay }
    }

    // MARK: - Lookup

    func testLookupResolvesEveryIdentifier() {
        XCTAssertEqual(lookup.index(forTripID: "T1"), 0)
        XCTAssertEqual(lookup.index(forTripID: "T2"), 1)
        XCTAssertNil(lookup.index(forTripID: "nope"))
        XCTAssertEqual(lookup.index(forStopID: "S3"), 2)
        XCTAssertEqual(lookup.index(forRouteID: "R1"), 0)
        XCTAssertEqual(lookup.pattern(ofTrip: 1), 0)
    }

    // MARK: - Propagation

    func testDelayPropagatesForwardFromTheUpdatedStop() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(
                    stopID: "S2",
                    arrival: RTStopTimeEvent(delay: 120),
                    departure: RTStopTimeEvent(delay: 120)
                )
            ])
        ])

        XCTAssertEqual(departureDelays(index), [nil, 120, 120, 120])
        XCTAssertEqual(index.coveredTripCount, 1)
        XCTAssertEqual(index.unmatchedTripCount, 0)
        XCTAssertFalse(index.isCancelled(trip: 0))
    }

    func testALaterUpdateOverridesTheCarriedDelay() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopID: "S1", departure: RTStopTimeEvent(delay: 60)),
                RTStopTimeUpdate(stopID: "S3", departure: RTStopTimeEvent(delay: 180))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [60, 60, 180, 180])
    }

    func testASingleSidedUpdateMirrorsOntoTheOtherSide() {
        let index = makeIndex([
            update(stops: [RTStopTimeUpdate(stopID: "S2", departure: RTStopTimeEvent(delay: 90))])
        ])

        let adjustment = index.adjustment(trip: 0, position: 1)
        XCTAssertEqual(adjustment?.departureDelay, 90)
        XCTAssertEqual(adjustment?.arrivalDelay, 90)
    }

    func testNoDataStopsThePropagation() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopID: "S1", departure: RTStopTimeEvent(delay: 60)),
                RTStopTimeUpdate(stopID: "S3", scheduleRelationship: .noData)
            ])
        ])

        // Positions 0 and 1 carry the delay; NO_DATA at position 2 ends it, and
        // nothing stale leaks through to position 3.
        XCTAssertEqual(departureDelays(index), [60, 60, nil, nil])
    }

    func testTripLevelDelayAppliesWhereNoStopUpdateDoes() {
        let index = makeIndex([
            update(tripDelay: 45, stops: [
                RTStopTimeUpdate(stopID: "S3", departure: RTStopTimeEvent(delay: 300))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [45, 45, 300, 300])
    }

    // MARK: - Cancellation and skipping

    func testCancelledTripIsCancelledAtEveryPosition() {
        let index = makeIndex([update(tripID: "T2", relationship: .canceled)])

        XCTAssertTrue(index.isCancelled(trip: 1))
        XCTAssertFalse(index.isCancelled(trip: 0))
        for position in 0..<RealtimeFixture.stopCount {
            let adjustment = index.adjustment(trip: 1, position: position)
            XCTAssertEqual(adjustment?.isCancelled, true)
            XCTAssertEqual(adjustment?.blocksBoarding, true)
        }
        XCTAssertNil(index.adjustment(trip: 0, position: 0))
    }

    func testDeletedTripIsTreatedAsCancelled() {
        let index = makeIndex([update(tripID: "T1", relationship: .deleted)])
        XCTAssertTrue(index.isCancelled(trip: 0))
    }

    func testSkippedStopBlocksBoardingWithoutCancellingTheTrip() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopID: "S1", departure: RTStopTimeEvent(delay: 60)),
                RTStopTimeUpdate(stopID: "S3", scheduleRelationship: .skipped)
            ])
        ])

        XCTAssertFalse(index.isCancelled(trip: 0))
        let skipped = index.adjustment(trip: 0, position: 2)
        XCTAssertEqual(skipped?.isSkipped, true)
        XCTAssertEqual(skipped?.isCancelled, false)
        XCTAssertEqual(skipped?.blocksBoarding, true)
        // The vehicle still runs, so the delay carries past the skipped stop.
        XCTAssertEqual(index.adjustment(trip: 0, position: 3)?.departureDelay, 60)
        XCTAssertEqual(index.adjustment(trip: 0, position: 3)?.blocksBoarding, false)
    }

    // MARK: - Absolute times

    func testAbsoluteTimeIsConvertedAgainstTheScheduledTime() throws {
        let midnight = try XCTUnwrap(RealtimeFixture.serviceDay.startOfDay(in: RealtimeFixture.timeZone))
        let scheduled = RealtimeFixture.scheduledDeparture(trip: 0, position: 1)
        let predicted = Int64(midnight.timeIntervalSince1970) + Int64(scheduled) + 90

        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopID: "S2", departure: RTStopTimeEvent(time: predicted))
            ])
        ])

        XCTAssertEqual(index.adjustment(trip: 0, position: 1)?.departureDelay, 90)
        XCTAssertEqual(index.adjustment(trip: 0, position: 3)?.departureDelay, 90)
    }

    func testAbsoluteArrivalUsesTheArrivalColumnNotTheDepartureColumn() throws {
        let midnight = try XCTUnwrap(RealtimeFixture.serviceDay.startOfDay(in: RealtimeFixture.timeZone))
        let scheduledArrival = RealtimeFixture.scheduledArrival(trip: 0, position: 2)
        let predicted = Int64(midnight.timeIntervalSince1970) + Int64(scheduledArrival) + 60

        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopID: "S3", arrival: RTStopTimeEvent(time: predicted))
            ])
        ])

        // If the conversion had used the departure column, the 30-second gap
        // between arrival and departure would show up here as 30.
        XCTAssertEqual(index.adjustment(trip: 0, position: 2)?.arrivalDelay, 60)
    }

    func testDelayWinsOverTimeWhenBothArePresent() throws {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(
                    stopID: "S2",
                    departure: RTStopTimeEvent(delay: 15, time: 1)
                )
            ])
        ])

        XCTAssertEqual(index.adjustment(trip: 0, position: 1)?.departureDelay, 15)
    }

    func testAbsurdAbsoluteTimeIsClampedRatherThanOverflowing() throws {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopID: "S2", departure: RTStopTimeEvent(time: Int64.max / 2))
            ])
        ])

        XCTAssertEqual(index.adjustment(trip: 0, position: 1)?.departureDelay, 86_400)
    }

    // MARK: - Position resolution

    func testStopSequenceIsUsedAsAnOrdinalWhenNoStopIDIsGiven() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopSequence: 2, departure: RTStopTimeEvent(delay: 240))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [nil, nil, 240, 240])
    }

    /// A feed numbering from 1 whose updates reach the final stop is detectable:
    /// no 0-based numbering can produce a sequence equal to the stop count.
    func testOneBasedStopSequencesAreShiftedWhenUnambiguous() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopSequence: 3, departure: RTStopTimeEvent(delay: 240)),
                RTStopTimeUpdate(stopSequence: 4, departure: RTStopTimeEvent(delay: 300))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [nil, nil, 240, 300])
    }

    func testStopSequenceBeyondThePatternIsIgnored() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopSequence: 99, departure: RTStopTimeEvent(delay: 240))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [nil, nil, nil, nil])
    }

    func testStopIDWinsOverAContradictoryStopSequence() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopSequence: 0, stopID: "S3", departure: RTStopTimeEvent(delay: 240))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [nil, nil, 240, 240])
    }

    func testUnknownStopIDFallsBackToTheSequence() {
        let index = makeIndex([
            update(stops: [
                RTStopTimeUpdate(stopSequence: 1, stopID: "not-in-graph", departure: RTStopTimeEvent(delay: 240))
            ])
        ])

        XCTAssertEqual(departureDelays(index), [nil, 240, 240, 240])
    }

    // MARK: - Unmatched trips

    func testAddedAndUnscheduledTripsAreCountedAndIgnored() {
        let index = makeIndex([
            update(tripID: "T1", relationship: .added),
            update(tripID: "T2", relationship: .unscheduled),
            update(tripID: "T1", relationship: .duplicated)
        ])

        XCTAssertEqual(index.unmatchedTripCount, 3)
        XCTAssertEqual(index.coveredTripCount, 0)
        XCTAssertNil(index.adjustment(trip: 0, position: 0))
    }

    func testUnknownTripIdentifierIsCounted() {
        let index = makeIndex([
            update(tripID: "no-such-trip", stops: [
                RTStopTimeUpdate(stopID: "S1", departure: RTStopTimeEvent(delay: 60))
            ])
        ])

        XCTAssertEqual(index.unmatchedTripCount, 1)
        XCTAssertEqual(index.coveredTripCount, 0)
    }

    func testTwoTripsAreKeptApart() {
        let index = makeIndex([
            update(tripID: "T1", stops: [RTStopTimeUpdate(stopID: "S1", departure: RTStopTimeEvent(delay: 60))]),
            update(tripID: "T2", stops: [RTStopTimeUpdate(stopID: "S1", departure: RTStopTimeEvent(delay: -120))])
        ])

        XCTAssertEqual(departureDelays(index, trip: 0), [60, 60, 60, 60])
        XCTAssertEqual(departureDelays(index, trip: 1), [-120, -120, -120, -120])
        XCTAssertEqual(index.coveredTripCount, 2)
    }

    // MARK: - The RealtimeSource surface

    func testAdjustedDepartureAppliesTheDelay() {
        let index = makeIndex([
            update(stops: [RTStopTimeUpdate(stopID: "S2", departure: RTStopTimeEvent(delay: 120))])
        ])

        let scheduled = RealtimeFixture.scheduledDeparture(trip: 0, position: 1)
        let adjusted = index.adjustedDeparture(trip: 0, position: 1, scheduled: scheduled)
        XCTAssertEqual(adjusted.time, scheduled + 120)
        XCTAssertEqual(adjusted.delay, 120)
        XCTAssertFalse(adjusted.blocked)

        // Position 0 has no data at all, which must not be reported as "on time".
        let untouched = index.adjustedDeparture(trip: 0, position: 0, scheduled: scheduled)
        XCTAssertNil(untouched.delay)
    }

    func testGeneratedAtIsCarriedThrough() {
        let stamp = Date(timeIntervalSince1970: 1_786_636_800)
        let index = makeIndex([], generatedAt: stamp)
        XCTAssertEqual(index.generatedAt, stamp)
        XCTAssertEqual(index.coveredTripCount, 0)
    }

    // MARK: - Alerts

    func testAlertsResolveInformedEntitiesToIndices() {
        let alert = RTAlert(
            entityID: "alert-1",
            activePeriods: [RTTimeRange(start: 1_786_636_800, end: 1_786_640_400)],
            informedEntities: [
                RTEntitySelector(routeID: "R1"),
                RTEntitySelector(stopID: "S3"),
                RTEntitySelector(trip: RTTripDescriptor(tripID: "T2")),
                RTEntitySelector(stopID: "unknown-stop")
            ],
            cause: .construction,
            effect: .detour,
            url: "https://example.test",
            headerText: "Detour",
            descriptionText: "Line 1 is on detour.",
            severityLevel: nil
        )

        let index = makeIndex([], alerts: [alert])
        XCTAssertEqual(index.alerts.count, 1)
        let resolved = index.alerts.first
        XCTAssertEqual(resolved?.id, "alert-1")
        XCTAssertEqual(resolved?.routes, [0])
        XCTAssertEqual(resolved?.stops, [2])
        XCTAssertEqual(resolved?.trips, [1])
        XCTAssertEqual(resolved?.effect, .detour)
        // No severity_level on the wire, so it is inferred from the effect.
        XCTAssertEqual(resolved?.severity, .warning)
        XCTAssertEqual(resolved?.activeFrom, Date(timeIntervalSince1970: 1_786_636_800))
        XCTAssertEqual(resolved?.activeUntil, Date(timeIntervalSince1970: 1_786_640_400))
    }

    func testAlertsWithNoTextAreDropped() {
        let alert = RTAlert(entityID: "empty", effect: .noService)
        let index = makeIndex([], alerts: [alert])
        XCTAssertTrue(index.alerts.isEmpty)
    }

    func testAlertWithNoActivePeriodIsAlwaysActive() {
        let alert = RTAlert(entityID: "a", effect: .noService, headerText: "Closed")
        let index = makeIndex([], alerts: [alert])
        let resolved = index.alerts.first
        XCTAssertNil(resolved?.activeFrom)
        XCTAssertNil(resolved?.activeUntil)
        XCTAssertEqual(resolved?.severity, .severe)
        XCTAssertTrue(resolved?.isActive(at: Date()) ?? false)
    }
}
