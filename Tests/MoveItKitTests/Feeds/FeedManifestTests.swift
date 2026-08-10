import XCTest
@testable import MoveItKit

final class FeedManifestTests: XCTestCase {
    // MARK: - Fixtures

    /// Whole seconds only: the manifest encodes dates as ISO-8601, which drops
    /// sub-second precision, so a `Date()` would not survive a round trip.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSource(id: String = "test-feed") -> FeedSource {
        FeedSource(
            id: id,
            name: "Test Feed",
            region: "Testville",
            countryCode: "IL",
            staticURL: URL(string: "https://example.org/feed.zip")!,
            realtimeAlertsURL: URL(string: "https://example.org/alerts.pb")!,
            requestHeaders: ["X-Test": "1"],
            attribution: "Test agency",
            licenseURL: URL(string: "https://example.org/licence")!,
            approximateDownloadMegabytes: 7,
            bounds: GeoBounds(minLatitude: 31, minLongitude: 34, maxLatitude: 33, maxLongitude: 36),
            defaultBoundingBox: GeoBounds(minLatitude: 31.5, minLongitude: 34.5, maxLatitude: 32.5, maxLongitude: 35.5)
        )
    }

    private func makeMetadata(feedIdentifier: String = "test-feed") -> GraphMetadata {
        var metadata = GraphMetadata()
        metadata.feedIdentifier = feedIdentifier
        metadata.feedName = "Test Feed"
        metadata.feedVersion = "2026-01-01"
        metadata.sourceURL = "https://example.org/feed.zip"
        metadata.builtAt = FeedManifestTests.fixedDate
        metadata.timeZoneIdentifier = "Asia/Jerusalem"
        metadata.calendarStart = ServiceDate(year: 2026, month: 1, day: 1)
        metadata.calendarDayCount = 30
        metadata.serviceBitsetStride = 4
        metadata.counts.stops = 120
        metadata.counts.routes = 8
        return metadata
    }

    private func makeInstalledFeed(id: String = "test-feed") -> InstalledFeed {
        InstalledFeed(
            id: id,
            source: makeSource(id: id),
            graphFileName: "\(id)-1700000000000.mvtg",
            installedAt: FeedManifestTests.fixedDate,
            metadata: makeMetadata(feedIdentifier: id),
            byteSize: 4_096
        )
    }

    private func makeManifest() -> FeedManifest {
        FeedManifest(
            feeds: [makeInstalledFeed(id: "alpha"), makeInstalledFeed(id: "beta")],
            activeFeedID: "beta",
            installRecords: [
                "alpha": FeedInstallRecord(
                    entityTag: "\"abc123\"",
                    lastModified: "Wed, 21 Oct 2025 07:28:00 GMT",
                    contentLength: 1_234_567,
                    checkedAt: FeedManifestTests.fixedDate,
                    downloadedAt: FeedManifestTests.fixedDate,
                    region: GeoBounds(minLatitude: 31.9, minLongitude: 34.6, maxLatitude: 32.3, maxLongitude: 35.05),
                    archiveFileName: "alpha.zip",
                    archiveByteSize: 1_234_567
                ),
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Coding

    func testRoundTripsThroughJSON() throws {
        let manifest = makeManifest()
        let data = try manifest.encoded()
        let decoded = try FeedManifest.decode(from: data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.feeds.count, 2)
        XCTAssertEqual(decoded.activeFeedID, "beta")
        XCTAssertEqual(decoded.installRecords["alpha"]?.entityTag, "\"abc123\"")
        XCTAssertEqual(decoded.installRecords["alpha"]?.region?.minLatitude, 31.9)
        XCTAssertEqual(decoded.feeds.first?.metadata.counts.stops, 120)
        XCTAssertEqual(decoded.feeds.first?.metadata.builtAt, FeedManifestTests.fixedDate)
    }

    func testDecodingSuppliesDefaultsForAbsentSections() throws {
        let json = Data(#"{"feeds":[]}"#.utf8)
        let decoded = try FeedManifest.decode(from: json)

        XCTAssertEqual(decoded.version, FeedManifest.currentVersion)
        XCTAssertTrue(decoded.feeds.isEmpty)
        XCTAssertNil(decoded.activeFeedID)
        XCTAssertTrue(decoded.installRecords.isEmpty)
    }

    func testDecodingRejectsAFutureVersion() throws {
        let json = Data(#"{"version":99,"feeds":[]}"#.utf8)
        XCTAssertThrowsError(try FeedManifest.decode(from: json)) { error in
            XCTAssertEqual(error as? FeedManifestError, .unsupportedVersion(99))
        }
    }

    func testSourceDecodesWithoutOptionalFields() throws {
        let json = Data(#"{"id":"minimal","staticURL":"https://example.org/x.zip"}"#.utf8)
        let source = try FeedManifest.makeDecoder().decode(FeedSource.self, from: json)

        XCTAssertEqual(source.id, "minimal")
        XCTAssertEqual(source.staticURL.absoluteString, "https://example.org/x.zip")
        XCTAssertTrue(source.requestHeaders.isEmpty)
        XCTAssertNil(source.bounds)
        XCTAssertEqual(source.approximateDownloadMegabytes, 0)
    }

    // MARK: - Atomic save

    func testSaveCreatesTheFileWhenAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(FeedManifest.fileName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try makeManifest().save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reloaded = try FeedManifest.load(from: url)
        XCTAssertEqual(reloaded, makeManifest())
    }

    func testSaveReplacesAnExistingFileAndLeavesNoTemporaries() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(FeedManifest.fileName)

        try makeManifest().save(to: url)

        var second = makeManifest()
        second.feeds.removeLast()
        second.activeFeedID = "alpha"
        try second.save(to: url)

        let reloaded = try FeedManifest.load(from: url)
        XCTAssertEqual(reloaded.feeds.count, 1)
        XCTAssertEqual(reloaded.activeFeedID, "alpha")

        // The staging file must not survive the replace.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".tmp") }, [])
        XCTAssertTrue(contents.contains(FeedManifest.fileName))
    }

    func testSaveIntoAMissingDirectoryCreatesIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("a/b/c", isDirectory: true)
        let url = nested.appendingPathComponent(FeedManifest.fileName)

        try makeManifest().save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Tolerant loading

    func testLoadOrEmptyToleratesAMissingFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(FeedManifest.fileName)

        let manifest = FeedManifest.loadOrEmpty(from: url)
        XCTAssertTrue(manifest.isEmpty)
        XCTAssertNil(manifest.activeFeedID)
    }

    func testLoadOrEmptyToleratesACorruptFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(FeedManifest.fileName)
        try Data("not json at all".utf8).write(to: url)

        XCTAssertThrowsError(try FeedManifest.load(from: url))
        XCTAssertTrue(FeedManifest.loadOrEmpty(from: url).isEmpty)
    }
}
