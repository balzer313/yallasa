import XCTest
@testable import YallaSaKit

/// The feed lifecycle: install, activate, refresh, remove.
///
/// The behaviour worth testing here is not the happy path but what survives a
/// failure. A half-installed timetable is the one state the app must never reach,
/// because it looks like a working timetable and answers every question wrongly.
final class FeedManagerTests: XCTestCase {

    // MARK: - Test doubles

    /// Stands in for the network. Writes a fixed payload and counts how often it
    /// was asked to, which is how the refresh tests prove a download was skipped.
    private final class StubArchiveProvider: FeedArchiveProviding, @unchecked Sendable {
        var payload: Data
        var failure: FeedDownloadError?
        var reportedValidators = FeedResourceValidators(entityTag: "v1")
        var probeValidators: FeedResourceValidators?
        private(set) var downloadCount = 0
        private(set) var probeCount = 0

        init(payload: Data = Data("not really a feed".utf8)) {
            self.payload = payload
        }

        func downloadArchive(
            from url: URL,
            headers: [String: String],
            to destination: URL,
            progress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> FeedDownloadOutcome {
            downloadCount += 1
            if let failure { throw failure }
            let total = Int64(payload.count)
            progress(total / 2, total)
            progress(total, total)
            try? FileManager.default.removeItem(at: destination)
            try payload.write(to: destination)
            return FeedDownloadOutcome(validators: reportedValidators, byteCount: total)
        }

        func validators(for url: URL, headers: [String: String]) async -> FeedResourceValidators? {
            probeCount += 1
            return probeValidators
        }
    }

    /// Stands in for the importer. Writes a real graph through `GraphFixture`, so
    /// the manager's output is genuinely openable, without paying for a compile.
    private final class StubCompiler: FeedGraphCompiling, @unchecked Sendable {
        var shouldFail = false
        private(set) var compileCount = 0

        func compile(
            archiveAt archive: URL,
            to destination: URL,
            options: GTFSImportOptions,
            isCancelled: @escaping @Sendable () -> Bool,
            progress: @escaping @Sendable (GTFSImportProgress) -> Void
        ) throws -> GraphMetadata {
            compileCount += 1
            progress(
                GTFSImportProgress(
                    phase: .stopTimes, fractionCompleted: 0.5, overallFraction: 0.5, detail: "halfway"
                )
            )
            if shouldFail {
                throw GTFSImportError.noUsableTrips
            }
            var metadata = try GraphFixture.twoLineNetwork().write(to: destination)
            metadata.feedIdentifier = options.feedIdentifier
            metadata.feedName = options.feedName
            return metadata
        }
    }

    // MARK: - Fixtures

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-feeds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func source(id: String = "test-city") -> FeedSource {
        FeedSource.custom(
            staticURL: URL(string: "https://example.test/\(id).zip")!,
            name: "Test City",
            region: "Testville",
            countryCode: "TT"
        ).replacingIdentifier(with: id)
    }

    private func makeManager(
        provider: StubArchiveProvider,
        compiler: StubCompiler
    ) throws -> FeedManager {
        try FeedManager(directory: directory, archiveProvider: provider, compiler: compiler)
    }

    // MARK: - Install and activate

    func testInstallThenActivateProducesAnOpenableGraph() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        let installed = try await manager.install(source(), region: nil) { _ in }

        XCTAssertEqual(installed.source.id, "test-city")
        XCTAssertGreaterThan(installed.byteSize, 0)
        XCTAssertEqual(installed.metadata.counts.stops, 5)

        let feeds = await manager.installedFeeds
        XCTAssertEqual(feeds.count, 1)

        let graph = try await manager.activate(installed.id)
        XCTAssertEqual(graph.stopCount, 5)

        let active = await manager.activeFeedID
        XCTAssertEqual(active, installed.id)
    }

    func testProgressIsReportedAcrossBothDownloadAndCompile() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        // The actor calls this from its own context, so collection needs a lock
        // rather than a plain captured array.
        let collector = ProgressCollector()
        _ = try await manager.install(source(), region: nil) { progress in
            collector.append(progress)
        }

        let stages = collector.stages()
        XCTAssertTrue(stages.contains(.downloading), "the download stage must be reported")
        XCTAssertTrue(stages.contains(.compiling), "the compile stage must be reported")

        let fractions = collector.fractions()
        XCTAssertTrue(
            fractions.allSatisfy { $0 >= 0 && $0 <= 1.0001 },
            "a progress fraction outside 0...1 drives a nonsense progress bar"
        )
        XCTAssertEqual(
            fractions, fractions.sorted(),
            "progress must never go backwards"
        )
    }

    // MARK: - Failure leaves nothing behind

    func testFailedCompileLeavesNoGraphAndNoManifestEntry() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        compiler.shouldFail = true
        let manager = try makeManager(provider: provider, compiler: compiler)

        do {
            _ = try await manager.install(source(), region: nil) { _ in }
            XCTFail("the install should have propagated the compile failure")
        } catch {
            // expected
        }

        let feeds = await manager.installedFeeds
        XCTAssertTrue(feeds.isEmpty, "a failed install must not appear as installed")

        let graphs = directory.appendingPathComponent(FeedManager.graphsDirectoryName)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: graphs.path)) ?? []
        XCTAssertTrue(
            leftovers.filter { $0.hasSuffix(".mvtg") }.isEmpty,
            "a failed compile must not leave a graph file that could later be opened"
        )
    }

    func testFailedDownloadLeavesAPreviouslyInstalledFeedIntact() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        let first = try await manager.install(source(id: "city-a"), region: nil) { _ in }
        _ = try await manager.activate(first.id)

        provider.failure = .httpStatus(503)
        do {
            _ = try await manager.install(source(id: "city-b"), region: nil) { _ in }
            XCTFail("the install should have propagated the download failure")
        } catch {
            // expected
        }

        let feeds = await manager.installedFeeds
        XCTAssertEqual(feeds.map(\.id), [first.id], "the working feed must survive a failed second install")

        let active = await manager.activeFeedID
        XCTAssertEqual(active, first.id)
    }

    // MARK: - Persistence

    func testManifestSurvivesAManagerRestart() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()

        let installedID: String
        do {
            let manager = try makeManager(provider: provider, compiler: compiler)
            let installed = try await manager.install(source(), region: nil) { _ in }
            _ = try await manager.activate(installed.id)
            installedID = installed.id
        }

        // A fresh manager over the same directory is what a relaunch looks like.
        let reopened = try makeManager(provider: provider, compiler: compiler)
        let feeds = await reopened.installedFeeds
        XCTAssertEqual(feeds.map(\.id), [installedID])

        let active = await reopened.activeFeedID
        XCTAssertEqual(active, installedID, "the active feed must be remembered across launches")

        let graph = try await reopened.activate(installedID)
        XCTAssertEqual(graph.stopCount, 5, "the graph on disk must still be openable")
    }

    // MARK: - Refresh

    func testRefreshIsSkippedWhileTheFeedIsYoungerThanTheMaximumAge() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        let installed = try await manager.install(source(), region: nil) { _ in }
        let downloadsAfterInstall = provider.downloadCount

        let changed = try await manager.refreshIfNeeded(
            installed.id, maximumAge: 3600
        ) { _ in }

        XCTAssertFalse(changed)
        XCTAssertEqual(
            provider.downloadCount, downloadsAfterInstall,
            "a feed installed seconds ago must not be re-downloaded"
        )
    }

    func testRefreshWithMatchingValidatorsSkipsTheDownload() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        let installed = try await manager.install(source(), region: nil) { _ in }
        let downloadsAfterInstall = provider.downloadCount
        let compilesAfterInstall = compiler.compileCount

        // The server reports the same ETag it did at install time.
        provider.probeValidators = FeedResourceValidators(entityTag: "v1")

        let changed = try await manager.refreshIfNeeded(
            installed.id, maximumAge: 0
        ) { _ in }

        XCTAssertFalse(changed, "an unchanged feed must not be reinstalled")
        XCTAssertEqual(provider.downloadCount, downloadsAfterInstall)
        XCTAssertEqual(compiler.compileCount, compilesAfterInstall)
    }

    func testRefreshWithNoValidatorsRedownloadsRatherThanAssumingUnchanged() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        let installed = try await manager.install(source(), region: nil) { _ in }
        let downloadsAfterInstall = provider.downloadCount

        // A server that offers neither ETag nor Last-Modified — which is exactly
        // the Israeli MOT case. "Cannot tell" has to mean "assume it changed",
        // because the alternative is a timetable that never updates again.
        provider.probeValidators = nil
        provider.reportedValidators = FeedResourceValidators(entityTag: "v2")

        let changed = try await manager.refreshIfNeeded(
            installed.id, maximumAge: 0
        ) { _ in }

        XCTAssertTrue(changed)
        XCTAssertGreaterThan(provider.downloadCount, downloadsAfterInstall)
    }

    // MARK: - Removal

    func testRemoveDeletesTheFeedAndClearsTheActiveSelection() async throws {
        let provider = StubArchiveProvider()
        let compiler = StubCompiler()
        let manager = try makeManager(provider: provider, compiler: compiler)

        let installed = try await manager.install(source(), region: nil) { _ in }
        _ = try await manager.activate(installed.id)

        try await manager.remove(installed.id)

        let feeds = await manager.installedFeeds
        XCTAssertTrue(feeds.isEmpty)

        let active = await manager.activeFeedID
        XCTAssertNil(active, "removing the active feed must not leave a dangling active id")

        let graphs = directory.appendingPathComponent(FeedManager.graphsDirectoryName)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: graphs.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasSuffix(".mvtg") }.isEmpty)
    }

    func testRemovingAFeedThatIsNotInstalledIsReported() async throws {
        let manager = try makeManager(provider: StubArchiveProvider(), compiler: StubCompiler())
        do {
            try await manager.remove("nope")
            XCTFail("removing an unknown feed should report it rather than succeed silently")
        } catch {
            // expected
        }
    }

    // MARK: - Disk accounting

    func testDiskUsageReflectsWhatWasInstalled() async throws {
        let manager = try makeManager(provider: StubArchiveProvider(), compiler: StubCompiler())
        let before = await manager.diskUsage
        _ = try await manager.install(source(), region: nil) { _ in }
        let after = await manager.diskUsage
        XCTAssertGreaterThan(after, before)
    }
}

// MARK: - Helpers

/// `install` calls its progress closure from the actor's context, so the test
/// needs somewhere thread-safe to put the values.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FeedInstallProgress] = []

    func append(_ progress: FeedInstallProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    func stages() -> Set<FeedInstallStage> {
        lock.lock()
        defer { lock.unlock() }
        return Set(values.map(\.stage))
    }

    func fractions() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values.map(\.fraction)
    }
}

private extension FeedSource {
    /// `FeedSource.custom` derives its id from the URL. The tests want a
    /// predictable one so assertions read clearly.
    func replacingIdentifier(with identifier: String) -> FeedSource {
        var copy = self
        copy.id = identifier
        return copy
    }
}
