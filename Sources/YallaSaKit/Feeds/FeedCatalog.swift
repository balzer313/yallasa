import Foundation

/// The list of feeds the app can install without the user obtaining anything.
///
/// **This catalogue is best-effort and will rot.** Transit agencies move their
/// GTFS endpoints without notice, retire hostnames, and occasionally put a
/// perfectly good feed behind a registration form. Nothing here is fetched from a
/// central registry at runtime — that would be another network dependency and
/// another thing to be offline about — so a broken entry stays broken until the
/// app ships again. Two consequences are deliberate:
///
/// 1. **The catalogue is short, and every URL in it was fetched and confirmed to
///    return a real archive.** A wrong URL is worse than a missing one: it costs
///    the user a download, a timeout, and their trust. Feeds needing an API key
///    or registration (WMATA, 511.org, most European aggregators, and Israel's
///    SIRI realtime) are out of scope by definition.
/// 2. **A custom URL is always available.** `FeedSource.custom(staticURL:name:)`
///    builds a source from anything the user pastes, and the installer treats it
///    identically to a bundled one. When an entry here dies, that is the escape
///    hatch — not a new app release.
///
/// Every entry is `https`, so the app needs no App Transport Security exception.
/// `cleartextHosts` is the single place that would change if that ever stopped
/// being true, and `FeedCatalogTests` fails if a cleartext URL appears without
/// being listed there.
public enum FeedCatalog {
    /// Hosts knowingly served over cleartext HTTP. Empty, and meant to stay that
    /// way; it exists so an exception is a visible, tested decision rather than a
    /// quiet edit to a URL string.
    public static let cleartextHosts: Set<String> = []

    public static let bundled: [FeedSource] = israel + newYork

    // MARK: - Israel
    //
    // One national archive: ~141 MB compressed, around a gigabyte expanded, 4,200
    // routes and 30,500 stops. Importing it whole is possible on a desktop and
    // hopeless on a phone, so it is published here as one entry per metro area —
    // identical URL, different clip box. The download is the same either way; the
    // import is what gets an order of magnitude cheaper.

    private static let israelNationalBounds = GeoBounds(
        minLatitude: 29.45, minLongitude: 34.20, maxLatitude: 33.35, maxLongitude: 35.70
    )

    private static let israelStaticURL = url("https://gtfs.mot.gov.il/gtfsfiles/israel-public-transportation.zip")

    private static let israelAttribution =
        "Israel Ministry of Transport and Road Safety — public transport open data"

    /// The MOT publishes SIRI rather than GTFS-realtime, and it needs a key, so
    /// both realtime URLs stay nil here.
    private static func israelSource(id: String, name: String, region: FeedRegion) -> FeedSource {
        FeedSource(
            id: id,
            name: name,
            region: region.name,
            countryCode: "IL",
            staticURL: israelStaticURL,
            attribution: israelAttribution,
            approximateDownloadMegabytes: 141,
            bounds: region.bounds,
            // A little wider than the region itself, so a route that dips just
            // outside the box still has both of its ends.
            defaultBoundingBox: region.bounds.expanded(byMeters: 8_000)
        )
    }

    private static let israel: [FeedSource] = [
        israelSource(id: "il-mot-tel-aviv", name: "Israel — Tel Aviv metro", region: FeedRegion.telAviv),
        israelSource(id: "il-mot-jerusalem", name: "Israel — Jerusalem", region: FeedRegion.jerusalem),
        israelSource(id: "il-mot-haifa", name: "Israel — Haifa and the Krayot", region: FeedRegion.haifa),
        FeedSource(
            id: "il-mot-national",
            name: "Israel — whole country",
            region: "Israel",
            countryCode: "IL",
            staticURL: israelStaticURL,
            attribution: israelAttribution,
            approximateDownloadMegabytes: 141,
            bounds: israelNationalBounds,
            // No default clip: this entry exists precisely for the caller who
            // wants everything, or who wants to draw their own box.
            defaultBoundingBox: nil
        ),
    ]

    // MARK: - New York
    //
    // The MTA splits its network across archives — subway, one per bus borough,
    // the bus company, LIRR, Metro-North — which suits a phone well: a rider who
    // only takes the subway never downloads the Queens bus network. Realtime has
    // needed no API key since 2023.
    //
    // Watch the file names: every feed uses an underscore (`gtfs_subway.zip`)
    // except the two railroads, which do not (`gtfslirr.zip`, `gtfsmnr.zip`).
    // The underscored spellings of those two return 403.

    private static let mtaTripUpdatesURL = url("https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs")
    private static let mtaAlertsURL = url("https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fall-alerts")
    private static let mtaAttribution = "Metropolitan Transportation Authority (MTA), New York"
    private static let mtaLicenseURL = url("https://www.mta.info/developers")

    private static func mtaFeed(
        id: String,
        name: String,
        file: String,
        region: FeedRegion,
        megabytes: Int,
        tripUpdates: URL? = nil
    ) -> FeedSource {
        FeedSource(
            id: id,
            name: name,
            region: region.name,
            countryCode: "US",
            staticURL: url("https://rrgtfsfeeds.s3.amazonaws.com/\(file)"),
            realtimeTripUpdatesURL: tripUpdates,
            // The all-alerts feed spans the whole MTA, so every entry gets it.
            realtimeAlertsURL: mtaAlertsURL,
            attribution: mtaAttribution,
            licenseURL: mtaLicenseURL,
            approximateDownloadMegabytes: megabytes,
            bounds: region.bounds,
            // These feeds are already city-sized; clipping them buys nothing.
            defaultBoundingBox: nil
        )
    }

    private static let newYork: [FeedSource] = [
        mtaFeed(
            id: "nyc-subway", name: "MTA Subway", file: "gtfs_subway.zip",
            region: FeedRegion.newYorkCity, megabytes: 5, tripUpdates: mtaTripUpdatesURL
        ),
        mtaFeed(
            // The supplemented archive folds in planned diversions and weekend
            // service changes, which is what riders actually experience — at four
            // times the size and with a shorter shelf life.
            id: "nyc-subway-supplemented", name: "MTA Subway (with planned changes)",
            file: "gtfs_supplemented.zip",
            region: FeedRegion.newYorkCity, megabytes: 19, tripUpdates: mtaTripUpdatesURL
        ),
        mtaFeed(
            id: "nyc-bus-manhattan", name: "MTA Bus — Manhattan", file: "gtfs_m.zip",
            region: FeedRegion.manhattan, megabytes: 6
        ),
        mtaFeed(
            id: "nyc-bus-brooklyn", name: "MTA Bus — Brooklyn", file: "gtfs_b.zip",
            region: FeedRegion.brooklyn, megabytes: 13
        ),
        mtaFeed(
            id: "nyc-bus-bronx", name: "MTA Bus — The Bronx", file: "gtfs_bx.zip",
            region: FeedRegion.bronx, megabytes: 6
        ),
        mtaFeed(
            id: "nyc-bus-queens", name: "MTA Bus — Queens", file: "gtfs_q.zip",
            region: FeedRegion.queens, megabytes: 4
        ),
        mtaFeed(
            id: "nyc-bus-staten-island", name: "MTA Bus — Staten Island", file: "gtfs_si.zip",
            region: FeedRegion.statenIsland, megabytes: 5
        ),
        mtaFeed(
            id: "nyc-bus-company", name: "MTA Bus Company (express routes)", file: "gtfs_busco.zip",
            region: FeedRegion.newYorkCity, megabytes: 5
        ),
        mtaFeed(
            id: "nyc-lirr", name: "Long Island Rail Road", file: "gtfslirr.zip",
            region: FeedRegion.longIsland, megabytes: 2
        ),
        mtaFeed(
            id: "nyc-metro-north", name: "Metro-North Railroad", file: "gtfsmnr.zip",
            region: FeedRegion.lowerHudsonAndConnecticut, megabytes: 4
        ),
    ]

    // MARK: - Queries

    public static func source(withID identifier: String) -> FeedSource? {
        bundled.first { $0.id == identifier }
    }

    /// Bundled feeds ordered by how close their served area is to `point`.
    ///
    /// Distance is measured to the centre of `bounds`, which is crude but is the
    /// right kind of crude: it puts the Tel Aviv clip of the national feed above
    /// the Jerusalem clip for someone in Ramat Gan, and puts every New York feed
    /// below both.
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

    /// Bundled feeds whose bounds contain `point`, nearest first. Used for "you
    /// appear to be in New York" rather than for the full picker.
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
