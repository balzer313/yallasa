import Foundation

/// The transit feeds the app can install without the user obtaining anything.
///
/// **Israel only.** This is a Hebrew-language app for Israeli public transport;
/// the New York entries this catalogue used to carry were a leftover from when
/// it was a generic GTFS reader, and every one of them was a feed no rider of
/// this app would ever install. Feeds elsewhere are still one paste away through
/// `FeedSource.custom(staticURL:name:)`, which is the honest escape hatch for a
/// catalogue that can never be complete.
///
/// **This catalogue is best-effort and will rot.** Transport authorities move
/// their GTFS endpoints without notice. Nothing here is fetched from a registry
/// at runtime — that would be another network dependency and another thing to be
/// offline about — so a broken entry stays broken until the app ships again.
///
/// Every entry is `https`, so the app needs no App Transport Security exception.
/// `cleartextHosts` is the single place that would change if that stopped being
/// true, and `FeedCatalogTests` fails if a cleartext URL appears without being
/// listed there.
public enum FeedCatalog {
    /// Hosts knowingly served over cleartext HTTP. Empty, and meant to stay that
    /// way; it exists so an exception is a visible, tested decision rather than a
    /// quiet edit to a URL string.
    public static let cleartextHosts: Set<String> = []

    public static let bundled: [FeedSource] = israel

    /// What a first run installs without asking.
    ///
    /// The whole country, unclipped. Clipping to a metro area was the answer to
    /// a memory ceiling that no longer applies now large tables inflate through
    /// a mapped file, and it made the app quietly wrong the moment a rider left
    /// the box — an intercity bus to Eilat simply did not exist. One nationwide
    /// install costs more on first run and is correct everywhere afterwards.
    public static let defaultSource: FeedSource = israelNational

    // MARK: - Israel
    //
    // One national archive from the Ministry of Transport: ~133 MB compressed,
    // about a gigabyte expanded, 7,600 routes and 30,500 stops.
    //
    // The metro clips below still exist for a rider who wants a smaller install
    // — the download is identical, the compile is an order of magnitude cheaper
    // — but they are no longer the default, and nothing steers anyone to them.

    private static let israelNationalBounds = GeoBounds(
        minLatitude: 29.45, minLongitude: 34.20, maxLatitude: 33.35, maxLongitude: 35.70
    )

    private static let israelStaticURL = url("https://gtfs.mot.gov.il/gtfsfiles/israel-public-transportation.zip")

    private static let israelAttribution =
        "Israel Ministry of Transport and Road Safety — public transport open data"

    /// The MOT publishes SIRI rather than GTFS-realtime, and its SIRI endpoint
    /// needs a registered key, so both realtime URLs stay nil: there are no trip
    /// updates for Israel and departure boards show scheduled times.
    ///
    /// Live *positions* are a different matter. Open Bus republishes the same MOT
    /// SIRI stream over a keyless JSON API, so `vehiclePositions` is set and the
    /// map shows buses actually moving. See `StrideVehicleSource`.
    private static let israelNational = FeedSource(
        id: "il-mot-national",
        name: "Israel — whole country",
        region: "Israel",
        countryCode: "IL",
        staticURL: israelStaticURL,
        attribution: israelAttribution,
        approximateDownloadMegabytes: 133,
        bounds: israelNationalBounds,
        // No clip: this entry exists precisely to cover everything.
        defaultBoundingBox: nil,
        vehiclePositions: .openBusStride
    )

    private static func israelSource(id: String, name: String, region: FeedRegion) -> FeedSource {
        FeedSource(
            id: id,
            name: name,
            region: region.name,
            countryCode: "IL",
            staticURL: israelStaticURL,
            attribution: israelAttribution,
            approximateDownloadMegabytes: 133,
            bounds: region.bounds,
            // A little wider than the region itself, so a route that dips just
            // outside the box still has both of its ends.
            defaultBoundingBox: region.bounds.expanded(byMeters: 8_000),
            vehiclePositions: .openBusStride
        )
    }

    private static let israel: [FeedSource] = [
        israelNational,
        israelSource(id: "il-mot-tel-aviv", name: "Israel — Tel Aviv metro", region: FeedRegion.telAviv),
        israelSource(id: "il-mot-jerusalem", name: "Israel — Jerusalem", region: FeedRegion.jerusalem),
        israelSource(id: "il-mot-haifa", name: "Israel — Haifa and the Krayot", region: FeedRegion.haifa),
    ]

    // MARK: - Queries

    public static func source(withID identifier: String) -> FeedSource? {
        bundled.first { $0.id == identifier }
    }

    /// Bundled feeds ordered by how close their served area is to `point`.
    ///
    /// Distance is measured to the centre of `bounds`, which is crude but is the
    /// right kind of crude: it puts the Tel Aviv clip above the Jerusalem clip
    /// for someone in Ramat Gan.
    public static func nearest(to point: GeoPoint) -> [FeedSource] {
        nearest(to: point, among: bundled)
    }

    public static func nearest(to point: GeoPoint, among sources: [FeedSource]) -> [FeedSource] {
        // The index is carried through the sort so equal distances keep their
        // declaration order; `sorted(by:)` is not documented to be stable.
        let ranked: [(order: Int, source: FeedSource, distance: Double)] =
            sources.enumerated().map { offset, source in
                guard let centre = source.centre else {
                    return (offset, source, Double.greatestFiniteMagnitude)
                }
                return (offset, source, point.distance(to: centre))
            }
        return ranked
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.order < rhs.order
            }
            .map { $0.source }
    }

    /// Bundled feeds whose bounds contain `point`, nearest first.
    public static func covering(_ point: GeoPoint) -> [FeedSource] {
        nearest(to: point, among: bundled.filter { $0.bounds?.contains(point) ?? false })
    }

    /// Catalogue URLs are compile-time constants checked by `FeedCatalogTests`;
    /// a malformed one is a programming error, not a runtime condition, so it
    /// fails loudly here rather than silently shrinking the catalogue.
    private static func url(_ string: String) -> URL {
        guard let parsed = URL(string: string), parsed.scheme != nil, parsed.host != nil else {
            preconditionFailure("FeedCatalog contains a malformed URL: \(string)")
        }
        return parsed
    }
}
