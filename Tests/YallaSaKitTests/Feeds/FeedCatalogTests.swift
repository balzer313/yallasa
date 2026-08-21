import XCTest
@testable import YallaSaKit

final class FeedCatalogTests: XCTestCase {
    private let telAviv = GeoPoint(latitude: 32.0853, longitude: 34.7818)
    private let jerusalem = GeoPoint(latitude: 31.7683, longitude: 35.2137)
    private let timesSquare = GeoPoint(latitude: 40.7580, longitude: -73.9855)

    // MARK: - Shape of the catalogue

    func testCatalogueIsNotEmpty() {
        XCTAssertFalse(FeedCatalog.bundled.isEmpty)
    }

    func testIdentifiersAreUnique() {
        let identifiers = FeedCatalog.bundled.map { $0.id }
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "duplicate feed identifier in the catalogue")
        for identifier in identifiers {
            XCTAssertFalse(identifier.isEmpty)
            XCTAssertEqual(identifier, identifier.lowercased(), "identifiers are used as file names; keep them lowercase")
        }
    }

    func testEverySourceIsUsableAsPresented() {
        for source in FeedCatalog.bundled {
            XCTAssertFalse(source.name.isEmpty, "\(source.id) has no name")
            XCTAssertFalse(source.region.isEmpty, "\(source.id) has no region")
            XCTAssertEqual(source.countryCode.count, 2, "\(source.id) has no ISO country code")
            XCTAssertFalse(source.attribution.isEmpty, "\(source.id) has no attribution")
            XCTAssertGreaterThan(source.approximateDownloadMegabytes, 0, "\(source.id) has no size estimate")
            XCTAssertNotNil(source.bounds, "\(source.id) has no bounds, so it can never be offered by proximity")
            XCTAssertEqual(source.bounds?.isEmpty, false, "\(source.id) has degenerate bounds")
        }
    }

    func testEveryURLIsAbsoluteAndWellFormed() {
        for source in FeedCatalog.bundled {
            assertUsable(source.staticURL, label: "\(source.id) staticURL")
            if let url = source.realtimeTripUpdatesURL { assertUsable(url, label: "\(source.id) tripUpdates") }
            if let url = source.realtimeAlertsURL { assertUsable(url, label: "\(source.id) alerts") }
            if let url = source.licenseURL { assertUsable(url, label: "\(source.id) licence") }
        }
    }

    /// Cleartext HTTP is a decision, not an accident: App Transport Security has
    /// to be opened up for every host that needs it, so a new one must be
    /// declared in `FeedCatalog.cleartextHosts` before this test will pass.
    func testCleartextURLsAreDeclared() {
        XCTAssertTrue(
            FeedCatalog.cleartextHosts.isEmpty,
            "cleartextHosts is no longer empty; the app target now needs a matching ATS exception"
        )

        for source in FeedCatalog.bundled {
            for url in [source.staticURL, source.realtimeTripUpdatesURL, source.realtimeAlertsURL, source.licenseURL] {
                guard let url else { continue }
                guard url.scheme?.lowercased() != "https" else { continue }
                XCTAssertEqual(url.scheme?.lowercased(), "http", "\(url) uses an unexpected scheme")
                let host = url.host?.lowercased() ?? ""
                XCTAssertTrue(
                    FeedCatalog.cleartextHosts.contains(host),
                    "\(url) is cleartext but \(host) is not declared in FeedCatalog.cleartextHosts"
                )
            }
        }
    }

    func testLookupByIdentifier() {
        for source in FeedCatalog.bundled {
            XCTAssertEqual(FeedCatalog.source(withID: source.id)?.id, source.id)
        }
        XCTAssertNil(FeedCatalog.source(withID: "no-such-feed"))
    }

    // MARK: - The national-feed trick

    func testIsraelSourcesShareOneArchiveButClipDifferently() throws {
        let israel = FeedCatalog.bundled.filter { $0.countryCode == "IL" }
        XCTAssertGreaterThanOrEqual(israel.count, 4)

        let urls = Set(israel.map { $0.staticURL })
        XCTAssertEqual(urls.count, 1, "the Israeli entries are one archive clipped several ways")

        let metros = israel.filter { $0.defaultBoundingBox != nil }
        XCTAssertGreaterThanOrEqual(metros.count, 3)
        let boxes = metros.compactMap { $0.defaultBoundingBox }
        XCTAssertEqual(Set(boxes).count, boxes.count, "two metro entries clip to the same box")

        for metro in metros {
            let box = try XCTUnwrap(metro.defaultBoundingBox)
            let bounds = try XCTUnwrap(metro.bounds)
            // The clip box is grown slightly so routes that leave the region keep
            // both of their ends.
            XCTAssertLessThan(box.minLatitude, bounds.minLatitude)
            XCTAssertGreaterThan(box.maxLatitude, bounds.maxLatitude)
            XCTAssertTrue(metro.needsRegionSelection)
        }

        let national = try XCTUnwrap(FeedCatalog.source(withID: "il-mot-national"))
        XCTAssertNil(national.defaultBoundingBox, "the nationwide entry must not clip silently")
    }

    func testIsraelHasNoRealtimeURLs() {
        for source in FeedCatalog.bundled where source.countryCode == "IL" {
            XCTAssertNil(source.realtimeTripUpdatesURL)
            XCTAssertNil(source.realtimeAlertsURL)
        }
    }

    func testEveryBundledFeedIsIsraeliAndOffersLivePositions() throws {
        XCTAssertFalse(FeedCatalog.bundled.isEmpty)
        for source in FeedCatalog.bundled {
            XCTAssertEqual(source.countryCode, "IL", "\(source.id) is not an Israeli feed")
            XCTAssertTrue(source.hasLiveVehicles, "\(source.id) should offer live positions")
            // MOT SIRI trip updates need a key, so none may claim otherwise.
            XCTAssertFalse(source.hasRealtime, "\(source.id) claims trip updates it cannot have")
        }
    }

    func testDefaultSourceIsTheWholeCountryAndUnclipped() {
        let fallback = FeedCatalog.defaultSource
        XCTAssertEqual(fallback.id, "il-mot-national")
        XCTAssertNil(fallback.defaultBoundingBox, "the default install must not clip")
        XCTAssertTrue(FeedCatalog.bundled.contains { $0.id == fallback.id })
        XCTAssertEqual(FeedCatalog.bundled.first?.id, fallback.id, "the default should lead the list")
    }

    // MARK: - Ordering

    func testNearestReturnsEverySourceExactlyOnce() {
        let ordered = FeedCatalog.nearest(to: telAviv)
        XCTAssertEqual(ordered.count, FeedCatalog.bundled.count)
        XCTAssertEqual(Set(ordered.map { $0.id }), Set(FeedCatalog.bundled.map { $0.id }))
    }

    func testNearestSortsByDistanceFromBoundsCentre() throws {
        let ordered = FeedCatalog.nearest(to: telAviv)

        XCTAssertEqual(ordered.first?.id, "il-mot-tel-aviv")

        // And the ordering really is monotonic in distance.
        var previous = -1.0
        for source in ordered {
            let centre = try XCTUnwrap(source.centre)
            let distance = telAviv.distance(to: centre)
            XCTAssertGreaterThanOrEqual(distance, previous)
            previous = distance
        }
    }

    func testNearestPrefersTheLocalMetroClip() throws {
        let ordered = FeedCatalog.nearest(to: jerusalem).filter { $0.countryCode == "IL" }
        XCTAssertEqual(ordered.first?.id, "il-mot-jerusalem")

        let jerusalemIndex = try XCTUnwrap(ordered.firstIndex { $0.id == "il-mot-jerusalem" })
        let haifaIndex = try XCTUnwrap(ordered.firstIndex { $0.id == "il-mot-haifa" })
        XCTAssertLessThan(jerusalemIndex, haifaIndex)
    }

    func testCoveringOnlyReturnsFeedsWhoseBoundsContainThePoint() {
        let covering = FeedCatalog.covering(telAviv)
        XCTAssertFalse(covering.isEmpty)
        for source in covering {
            XCTAssertEqual(source.bounds?.contains(telAviv), true)
        }
    }

    /// The catalogue is Israel-only now, so a point in Manhattan matches nothing.
    func testCoveringIsEmptyOutsideIsrael() {
        XCTAssertTrue(FeedCatalog.covering(timesSquare).isEmpty)
    }

    func testEmptyInputIsHandled() {
        XCTAssertTrue(FeedCatalog.nearest(to: telAviv, among: []).isEmpty)
    }

    // MARK: - Custom sources

    func testCustomSourceIsStableAndDistinct() throws {
        let url = try XCTUnwrap(URL(string: "https://example.org/somewhere/gtfs.zip"))
        let first = FeedSource.custom(staticURL: url, name: "Somewhere")
        let second = FeedSource.custom(staticURL: url, name: "Somewhere")
        let other = FeedSource.custom(
            staticURL: try XCTUnwrap(URL(string: "https://example.org/else/gtfs.zip")),
            name: "Else"
        )

        XCTAssertEqual(first.id, second.id, "the same URL must map to the same feed on every launch")
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertTrue(first.id.hasPrefix("custom-"))
        XCTAssertFalse(FeedCatalog.bundled.contains { $0.id == first.id })
    }

    // MARK: - Regions

    func testRegionsPointAtRealCatalogueEntries() {
        let identifiers = Set(FeedCatalog.bundled.map { $0.id })
        for region in FeedRegion.all {
            guard let feedSourceID = region.feedSourceID else { continue }
            XCTAssertTrue(
                identifiers.contains(feedSourceID),
                "region \(region.id) points at missing feed \(feedSourceID)"
            )
        }
    }

    func testRegionSuggestionPrefersTheTightestMatch() throws {
        let suggested = try XCTUnwrap(FeedRegion.suggested(for: telAviv))
        XCTAssertEqual(suggested.id, FeedRegion.telAviv.id)

        let manhattan = try XCTUnwrap(FeedRegion.suggested(for: timesSquare))
        XCTAssertEqual(manhattan.id, FeedRegion.manhattan.id, "the borough is a better answer than the whole city")
    }

    func testRegionSuggestionGivesUpWhenFarAway() {
        // Mid-Pacific: nothing in the catalogue is remotely relevant.
        XCTAssertNil(FeedRegion.suggested(for: GeoPoint(latitude: -10, longitude: -140)))
    }

    func testBoxAroundAPointIsCentredOnIt() {
        let box = FeedRegion.box(around: telAviv, radiusKilometres: 20)
        XCTAssertTrue(box.contains(telAviv))
        XCTAssertEqual(box.center.latitude, telAviv.latitude, accuracy: 0.0001)
        XCTAssertEqual(box.center.longitude, telAviv.longitude, accuracy: 0.0001)
        XCTAssertFalse(box.contains(GeoPoint(latitude: telAviv.latitude + 1, longitude: telAviv.longitude)))
    }

    // MARK: - Helpers

    private func assertUsable(_ url: URL, label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(url.scheme, "\(label) has no scheme", file: file, line: line)
        XCTAssertNotNil(url.host, "\(label) is not absolute", file: file, line: line)
        XCTAssertFalse(url.absoluteString.contains(" "), "\(label) contains a space", file: file, line: line)
        XCTAssertTrue(
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            "\(label) is not an HTTP(S) URL",
            file: file,
            line: line
        )
    }
}
