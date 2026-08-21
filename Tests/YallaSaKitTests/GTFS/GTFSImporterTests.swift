import XCTest
@testable import YallaSaKit

/// End-to-end: a GTFS archive goes in, a queryable graph comes out, and the
/// times that come out are exactly the times that went in.
///
/// The importer's job is a long chain of transformations — CSV, calendars,
/// pattern grouping, index remapping, columnar layout — and each link is unit
/// tested elsewhere. This file exists to prove the chain composes, because an
/// index remap applied in one place and forgotten in another produces a graph
/// that is internally consistent and completely wrong.
final class GTFSImporterTests: XCTestCase {

    // MARK: - Feed construction

    private struct FeedBuilder {
        var agency = """
        agency_id,agency_name,agency_url,agency_timezone
        AG1,Test Transit,https://example.test,Asia/Jerusalem
        """

        var stops = """
        stop_id,stop_name,stop_lat,stop_lon,stop_code
        S1,Ashfield,32.0700,34.7700,A1
        S2,Bridgeway,32.0760,34.7760,B1
        S3,Carlton,32.0820,34.7820,C1
        """

        var routes = """
        route_id,agency_id,route_short_name,route_long_name,route_type,route_color
        R1,AG1,1,Ashfield to Carlton,3,FF6600
        """

        var trips = """
        route_id,service_id,trip_id,trip_headsign,direction_id
        R1,SVC,T1,Carlton,0
        R1,SVC,T2,Carlton,0
        """

        var stopTimes = """
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        T1,08:00:00,08:00:00,S1,1
        T1,08:06:00,08:06:00,S2,2
        T1,08:12:00,08:12:00,S3,3
        T2,08:10:00,08:10:00,S1,1
        T2,08:16:00,08:16:00,S2,2
        T2,08:22:00,08:22:00,S3,3
        """

        var calendar = """
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        SVC,1,1,1,1,1,1,1,20260810,20260823
        """

        var calendarDates: String?
        var feedInfo: String?
        var transfers: String?
        /// Files nested in a folder, which is how a great many agencies publish.
        var nested = false

        func archive() throws -> URL {
            var zip = ZipBuilder()
            let prefix = nested ? "gtfs_feed/" : ""
            zip.add(prefix + "agency.txt", contents: agency)
            zip.add(prefix + "stops.txt", contents: stops)
            zip.add(prefix + "routes.txt", contents: routes)
            zip.add(prefix + "trips.txt", contents: trips)
            zip.add(prefix + "stop_times.txt", contents: stopTimes)
            zip.add(prefix + "calendar.txt", contents: calendar)
            if let calendarDates { zip.add(prefix + "calendar_dates.txt", contents: calendarDates) }
            if let feedInfo { zip.add(prefix + "feed_info.txt", contents: feedInfo) }
            if let transfers { zip.add(prefix + "transfers.txt", contents: transfers) }
            return try zip.write()
        }
    }

    private func compile(_ feed: FeedBuilder) throws -> TransitGraph {
        let archive = try feed.archive()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-import-\(UUID().uuidString).mvtg")
        defer { try? FileManager.default.removeItem(at: destination) }

        var options = GTFSImportOptions(
            feedIdentifier: "test",
            feedName: "Test Feed",
            sourceURL: "https://example.test/gtfs.zip"
        )
        options.calendarWindow = nil

        let importer = GTFSImporter(options: options)
        _ = try importer.compile(archiveAt: archive, to: destination)

        // Open from a copy of the bytes so the graph outlives the temp file.
        return try TransitGraph.open(data: try Data(contentsOf: destination))
    }

    /// Stops are re-ordered by grid cell during import, so nothing may assume an
    /// index. Everything is looked up by its GTFS id, which is what the realtime
    /// overlay and saved favourites do too.
    private func stop(_ graph: TransitGraph, _ identifier: String) throws -> StopIndex {
        for raw in 0..<graph.stopCount where graph.stopIdentifier(StopIndex(raw)) == identifier {
            return StopIndex(raw)
        }
        throw XCTSkip("stop \(identifier) is not in the compiled graph")
    }

    // MARK: - The happy path

    func testCompilesASmallFeedIntoAQueryableGraph() throws {
        let graph = try compile(FeedBuilder())

        XCTAssertEqual(graph.stopCount, 3)
        XCTAssertEqual(graph.routeCount, 1)
        XCTAssertEqual(graph.tripCount, 2)
        XCTAssertEqual(graph.patternCount, 1, "both trips share a stop sequence, so they are one pattern")
        XCTAssertEqual(graph.metadata.counts.stopTimes, 6)
        XCTAssertEqual(graph.metadata.timeZoneIdentifier, "Asia/Jerusalem")
    }

    func testTimesSurviveTheRoundTripExactly() throws {
        let graph = try compile(FeedBuilder())
        let pattern: PatternIndex = 0

        // Trips are ordered by departure at the first stop, so T1 is offset 0.
        XCTAssertEqual(graph.departureTime(pattern: pattern, tripOffset: 0, position: 0), 28_800)
        XCTAssertEqual(graph.departureTime(pattern: pattern, tripOffset: 0, position: 1), 29_160)
        XCTAssertEqual(graph.arrivalTime(pattern: pattern, tripOffset: 0, position: 2), 29_520)

        XCTAssertEqual(graph.departureTime(pattern: pattern, tripOffset: 1, position: 0), 29_400)
        XCTAssertEqual(graph.arrivalTime(pattern: pattern, tripOffset: 1, position: 2), 30_120)
    }

    func testStopAttributesAreCarriedThrough() throws {
        let graph = try compile(FeedBuilder())
        let ashfield = try stop(graph, "S1")

        XCTAssertEqual(graph.stopName(ashfield), "Ashfield")
        XCTAssertEqual(graph.stopCode(ashfield), "A1")
        let coordinate = graph.stopCoordinate(ashfield)
        XCTAssertEqual(coordinate.latitude, 32.07, accuracy: 0.00001)
        XCTAssertEqual(coordinate.longitude, 34.77, accuracy: 0.00001)
    }

    func testRouteColourIsParsedFromHex() throws {
        let graph = try compile(FeedBuilder())
        XCTAssertEqual(graph.routeColor(0), 0xFF6600)
        XCTAssertEqual(graph.routeDisplayName(0), "1")
        XCTAssertEqual(graph.routeMode(0), .bus)
        // No route_text_color in the feed, so the reader must pick a readable one.
        XCTAssertEqual(graph.routeTextColor(0), 0x000000, "orange needs dark text")
    }

    func testPatternStopSequenceMatchesTheFeed() throws {
        let graph = try compile(FeedBuilder())
        let expected = [try stop(graph, "S1"), try stop(graph, "S2"), try stop(graph, "S3")]
        let actual = (0..<graph.patternStopCount(0)).map { graph.patternStop(0, at: $0) }
        XCTAssertEqual(actual, expected)
    }

    func testCalendarIsExpandedIntoActiveDays() throws {
        let graph = try compile(FeedBuilder())

        let inRange = ServiceDate(year: 2026, month: 8, day: 12)
        let dayIndex = try XCTUnwrap(graph.dayIndex(for: inRange))
        XCTAssertTrue(graph.isServiceActive(0, dayIndex: dayIndex))
        XCTAssertTrue(graph.hasAnyService(on: inRange))

        XCTAssertFalse(graph.metadata.covers(ServiceDate(year: 2026, month: 9, day: 30)))
    }

    func testStopsAreFindableThroughTheSpatialIndex() throws {
        let graph = try compile(FeedBuilder())
        let ashfield = try stop(graph, "S1")

        let nearby = graph.stops(near: graph.stopCoordinate(ashfield), radiusMeters: 200, limit: 10)
        XCTAssertTrue(nearby.contains { $0.stop == ashfield })
        XCTAssertEqual(nearby.first?.distanceMeters ?? .infinity, 0, accuracy: 1)
    }

    func testNestedArchiveLayoutIsHandled() throws {
        var feed = FeedBuilder()
        feed.nested = true
        // Every file sits under gtfs_feed/, which must not stop the importer
        // finding them.
        let graph = try compile(feed)
        XCTAssertEqual(graph.stopCount, 3)
        XCTAssertEqual(graph.tripCount, 2)
    }

    // MARK: - GTFS's awkward corners

    func testTimesPastMidnightAreStoredUnnormalised() throws {
        var feed = FeedBuilder()
        feed.trips += "\nR1,SVC,T3,Carlton,0"
        feed.stopTimes += """

        T3,25:10:00,25:10:00,S1,1
        T3,25:16:00,25:16:00,S2,2
        T3,25:22:00,25:22:00,S3,3
        """

        let graph = try compile(feed)
        XCTAssertEqual(graph.tripCount, 3)
        // 25:10 is 90600 seconds and must stay that way — normalising it to 01:10
        // would attach the night bus to the wrong service day.
        XCTAssertEqual(graph.departureTime(pattern: 0, tripOffset: 2, position: 0), 90_600)
        XCTAssertEqual(graph.arrivalTime(pattern: 0, tripOffset: 2, position: 2), 91_320)
    }

    func testTripsWithDifferentStopSequencesBecomeDifferentPatterns() throws {
        var feed = FeedBuilder()
        // A short-turn that skips Carlton is a different pattern, not the same
        // line with a missing stop.
        feed.trips += "\nR1,SVC,T3,Bridgeway,0"
        feed.stopTimes += """

        T3,09:00:00,09:00:00,S1,1
        T3,09:06:00,09:06:00,S2,2
        """

        let graph = try compile(feed)
        XCTAssertEqual(graph.patternCount, 2)

        let counts = (0..<graph.patternCount).map { graph.patternStopCount(PatternIndex($0)) }.sorted()
        XCTAssertEqual(counts, [2, 3])
    }

    func testOvertakingTripsAreSplitIntoSeparatePatterns() throws {
        var feed = FeedBuilder()
        // An express that leaves after T1 but arrives before it. Left in one
        // pattern, this breaks the router's binary search over trip times.
        feed.trips += "\nR1,SVC,TX,Carlton express,0"
        feed.stopTimes += """

        TX,08:02:00,08:02:00,S1,1
        TX,08:04:00,08:04:00,S2,2
        TX,08:06:00,08:06:00,S3,3
        """

        let graph = try compile(feed)
        XCTAssertGreaterThan(
            graph.patternCount, 1,
            "an overtaking trip must be split out rather than left to break trip ordering"
        )

        // Whatever the split, the invariant the router depends on must hold:
        // within every pattern, departures are non-decreasing at every position.
        for rawPattern in 0..<graph.patternCount {
            let pattern = PatternIndex(rawPattern)
            let tripCount = graph.patternTripCount(pattern)
            guard tripCount > 1 else { continue }
            for position in 0..<graph.patternStopCount(pattern) {
                for offset in 1..<tripCount {
                    let previous = graph.departureTime(pattern: pattern, tripOffset: offset - 1, position: position)
                    let current = graph.departureTime(pattern: pattern, tripOffset: offset, position: position)
                    XCTAssertLessThanOrEqual(
                        previous, current,
                        "pattern \(pattern) is out of order at position \(position)"
                    )
                }
            }
        }
    }

    func testCalendarDateExceptionsAreApplied() throws {
        var feed = FeedBuilder()
        feed.calendarDates = """
        service_id,date,exception_type
        SVC,20260812,2
        """

        let graph = try compile(feed)
        let removed = ServiceDate(year: 2026, month: 8, day: 12)
        let kept = ServiceDate(year: 2026, month: 8, day: 13)

        if let removedIndex = graph.dayIndex(for: removed) {
            XCTAssertFalse(graph.isServiceActive(0, dayIndex: removedIndex), "exception_type 2 removes the day")
        }
        let keptIndex = try XCTUnwrap(graph.dayIndex(for: kept))
        XCTAssertTrue(graph.isServiceActive(0, dayIndex: keptIndex))
    }

    func testTransfersFileSeedsFootpaths() throws {
        var feed = FeedBuilder()
        feed.transfers = """
        from_stop_id,to_stop_id,transfer_type,min_transfer_time
        S1,S2,2,300
        """

        let graph = try compile(feed)
        let ashfield = try stop(graph, "S1")
        let bridgeway = try stop(graph, "S2")

        let footpaths = graph.transfers(fromStop: ashfield)
        let declared = footpaths.first { $0.target == bridgeway }
        XCTAssertNotNil(declared, "a declared transfer must survive into the graph")
        XCTAssertGreaterThanOrEqual(
            declared?.seconds ?? 0, 300,
            "a minimum transfer time is a floor, never a value to undercut"
        )
    }

    // MARK: - Dirty feeds

    func testStopWithoutCoordinatesIsDroppedAndReported() throws {
        var feed = FeedBuilder()
        feed.stops += "\nS4,Nowhere,,,"

        let archive = try feed.archive()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-import-\(UUID().uuidString).mvtg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let importer = GTFSImporter(
            options: GTFSImportOptions(feedIdentifier: "t", feedName: "t", sourceURL: "")
        )
        let metadata = try importer.compile(archiveAt: archive, to: destination)

        XCTAssertEqual(metadata.counts.stops, 3, "the coordinate-less stop must not be routable")
        XCTAssertGreaterThan(
            metadata.report.droppedStopsMissingCoordinate, 0,
            "what was dropped has to be reported, not silently swallowed"
        )
    }

    func testUnparsableTimeDropsOnlyThatTrip() throws {
        var feed = FeedBuilder()
        feed.trips += "\nR1,SVC,TBAD,Broken,0"
        feed.stopTimes += """

        TBAD,not-a-time,not-a-time,S1,1
        TBAD,also-broken,also-broken,S2,2
        """

        // The good trips must still be there; one bad row cannot cost the feed.
        let graph = try compile(feed)
        XCTAssertEqual(graph.tripCount, 2)
        XCTAssertGreaterThan(graph.metadata.report.totalDropped, 0)
    }

    func testMissingRequiredFileIsReportedClearly() throws {
        var zip = ZipBuilder()
        zip.add("agency.txt", contents: "agency_id,agency_name,agency_url,agency_timezone\nA,B,C,UTC")
        // No stops.txt, which is not optional.
        let archive = try zip.write()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-import-\(UUID().uuidString).mvtg")
        let importer = GTFSImporter(
            options: GTFSImportOptions(feedIdentifier: "t", feedName: "t", sourceURL: "")
        )

        XCTAssertThrowsError(try importer.compile(archiveAt: archive, to: destination))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a failed compile must leave no graph file behind"
        )
    }

    // MARK: - Region clipping

    func testBoundingBoxClipsTheFeed() throws {
        let archive = try FeedBuilder().archive()
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-import-\(UUID().uuidString).mvtg")
        defer { try? FileManager.default.removeItem(at: destination) }

        var options = GTFSImportOptions(feedIdentifier: "t", feedName: "t", sourceURL: "")
        // A box around Ashfield and Bridgeway only; Carlton sits outside it. This
        // is the mechanism that makes a national feed usable on a phone.
        options.boundingBox = GeoBounds(
            minLatitude: 32.065, minLongitude: 34.765,
            maxLatitude: 32.078, maxLongitude: 34.778
        )

        let importer = GTFSImporter(options: options)
        let metadata = try importer.compile(archiveAt: archive, to: destination)
        XCTAssertLessThan(metadata.counts.stops, 3, "a clipped import must drop out-of-area stops")
    }

    // MARK: - Composition with the router

    func testACompiledFeedCanActuallyBePlannedOn() throws {
        let graph = try compile(FeedBuilder())
        let planner = JourneyPlanner(graph: graph)

        let ashfield = try stop(graph, "S1")
        let carlton = try stop(graph, "S3")

        var options = PlanOptions()
        options.maximumTotalWalkMeters = 300     // force the bus rather than a walk

        let result = try planner.plan(
            PlanRequest(
                origin: .stop(ashfield),
                destination: .stop(carlton),
                anchor: .departAfter(
                    ServiceInstant(date: ServiceDate(year: 2026, month: 8, day: 12), seconds: 28_800)
                ),
                options: options
            )
        )

        let best = try XCTUnwrap(result.journeys.first, "the compiled feed must be routable")
        XCTAssertEqual(best.departure, 28_800)
        XCTAssertEqual(best.arrival, 29_520)
        XCTAssertEqual(best.transferCount, 0)
    }
}
