import XCTest
@testable import YallaSaKit

/// Imports the **real** Israeli feed and tries to plan a real journey.
///
/// Every other test here runs against fixtures, which is exactly how a router
/// can be provably correct and still return nothing on the only feed the app
/// ships. Two symptoms sent me here — no live buses, and "no journeys found"
/// every time — and neither reproduces against a hand-built graph.
///
/// **Skipped unless `YALLASA_REAL_FEED_TESTS=1`.** It downloads 133 MB and
/// compiles a large fraction of a gigabyte, which has no business in normal CI.
final class RealIsraelFeedDiagnosticTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["YALLASA_REAL_FEED_TESTS"] == "1"
    }

    /// Tel Aviv, clipped. The same pipeline as a national import at a fraction
    /// of the time; this is a diagnostic, not a capacity test.
    private let telAvivBox = GeoBounds(
        minLatitude: 32.00, minLongitude: 34.70,
        maxLatitude: 32.15, maxLongitude: 34.90
    )

    private static var cachedArchive: URL?

    private func archive() async throws -> URL {
        if let cached = Self.cachedArchive, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let url = FeedCatalog.defaultSource.staticURL
        print("downloading \(url.absoluteString) …")
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse { print("HTTP \(http.statusCode)") }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("israel-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        print("archive: \((attributes[.size] as? Int64) ?? 0) bytes")
        Self.cachedArchive = destination
        return destination
    }

    private func compile(clippedTo box: GeoBounds?, label: String) async throws -> TransitGraph {
        let archiveURL = try await archive()
        var options = GTFSImportOptions(
            feedIdentifier: "il-\(label)",
            feedName: "Israel \(label)",
            sourceURL: FeedCatalog.defaultSource.staticURL.absoluteString
        )
        options.boundingBox = box

        let graphURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("israel-\(label)-\(UUID().uuidString).mvtg")

        let started = Date()
        _ = try GTFSImporter(options: options).compile(archiveAt: archiveURL, to: graphURL)
        print("compiled \(label) in \(Int(Date().timeIntervalSince(started)))s")
        return try TransitGraph(memory: GraphMemory.map(contentsOf: graphURL))
    }

    // MARK: - What the graph actually contains

    func testImportsTheRealFeedAndReportsWhatItBuilt() async throws {
        try XCTSkipUnless(isEnabled, "set YALLASA_REAL_FEED_TESTS=1")

        let graph = try await compile(clippedTo: telAvivBox, label: "telaviv")
        let metadata = graph.metadata

        print("--- graph ---")
        print("stops         : \(graph.stopCount)")
        print("routes        : \(graph.routeCount)")
        print("patterns      : \(graph.patternCount)")
        print("trips         : \(graph.tripCount)")
        print("timezone      : \(metadata.timeZoneIdentifier)")
        print("bounds        : \(metadata.bounds)")

        // The prime suspect for "no journeys, ever". A graph whose calendar does
        // not cover today answers every query with nothing, confidently.
        print("--- calendar ---")
        print("calendarStart : \(metadata.calendarStart.gtfsString)")
        print("calendarDays  : \(metadata.calendarDayCount)")
        print("calendarEnd   : \(metadata.calendarEnd?.gtfsString ?? "nil")")

        let today = ServiceDate(date: Date(), in: graph.timeZone)
        print("today         : \(today.gtfsString)")
        print("covers today  : \(metadata.covers(today))")

        print("--- import report ---")
        print(metadata.report)

        XCTAssertGreaterThan(graph.stopCount, 100)
        XCTAssertGreaterThan(graph.routeCount, 10)
        XCTAssertGreaterThan(graph.tripCount, 100)
        XCTAssertTrue(
            metadata.covers(today),
            "the compiled calendar does not include today — every plan will return nothing"
        )
    }

    // MARK: - The reported symptom

    func testPlansAJourneyAcrossTelAviv() async throws {
        try XCTSkipUnless(isEnabled, "set YALLASA_REAL_FEED_TESTS=1")

        let graph = try await compile(clippedTo: telAvivBox, label: "plan")
        let planner = JourneyPlanner(graph: graph)

        // Two real, busy Tel Aviv places about 4 km apart.
        let savidor = GeoPoint(latitude: 32.0855, longitude: 34.7995)
        let florentin = GeoPoint(latitude: 32.0565, longitude: 34.7690)

        print("--- access stops ---")
        let nearOrigin = graph.nearestStops(to: savidor, limit: 10, maximumRadiusMeters: 800)
        let nearDestination = graph.nearestStops(to: florentin, limit: 10, maximumRadiusMeters: 800)
        print("within 800 m of origin      : \(nearOrigin.count)")
        print("within 800 m of destination : \(nearDestination.count)")
        XCTAssertFalse(nearOrigin.isEmpty, "no stops near Savidor Center — the clip or the grid is wrong")
        XCTAssertFalse(nearDestination.isEmpty, "no stops near Florentin")

        // Try several departure times. A single instant that happens to land in
        // a gap would look exactly like a broken router.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = graph.timeZone

        var anySucceeded = false
        for (label, target) in try weekdayProbes(calendar: calendar) {
            let instant = ServiceInstant(date: target, in: graph.timeZone)
            let request = PlanRequest(
                origin: .coordinate(savidor),
                destination: .coordinate(florentin),
                anchor: .departAfter(instant)
            )
            let result = try planner.plan(request, realtime: EmptyRealtimeSource.shared)
            print("\(label) [\(instant.date.gtfsString) \(instant.seconds)s] -> \(result.journeys.count) journeys")
            if let first = result.journeys.first {
                print("    depart \(first.departure) arrive \(first.arrival) legs \(first.legs.count)")
            }
            if !result.journeys.isEmpty { anySucceeded = true }
        }

        XCTAssertTrue(anySucceeded, "the planner found nothing between two central Tel Aviv points at any time tried")
    }

    /// A weekday morning, a weekday evening, and tomorrow — so a Shabbat run or
    /// an unlucky gap cannot masquerade as a broken router.
    private func weekdayProbes(calendar: Calendar) throws -> [(String, Date)] {
        var probes: [(String, Date)] = []
        for (label, weekday, hour) in [("Tue 08:00", 3, 8), ("Tue 12:00", 3, 12), ("Wed 17:00", 4, 17)] {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = hour
            components.minute = 0
            if let date = calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) {
                probes.append((label, date))
            }
        }
        probes.append(("now", Date()))
        return probes
    }
}
