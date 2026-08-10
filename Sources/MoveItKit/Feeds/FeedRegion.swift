import Foundation

/// A named box to clip a feed to at import time.
///
/// This exists because of one hard constraint: several of the best key-free GTFS
/// feeds are *national*. Israel's is a single archive covering the whole country
/// — a few million stop times, roughly a gigabyte uncompressed — and importing
/// all of it on a phone is neither fast nor useful to someone who only ever
/// travels between Tel Aviv and Herzliya. Clipping to a metro area before the
/// pattern builder runs cuts the import by an order of magnitude and changes
/// nothing a rider would notice.
///
/// The boxes are deliberately generous. A stop just outside the box is a stop the
/// router cannot use, and the cost of an extra 15 km of margin is a few thousand
/// stop times, so every box here is drawn to include the commuter belt rather
/// than the municipal boundary.
public struct FeedRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// ISO 3166-1 alpha-2, uppercased.
    public var countryCode: String
    public var bounds: GeoBounds
    /// The catalogue entry this region is meant to be applied to, when there is
    /// an obvious one. Nil means "usable with any feed covering it".
    public var feedSourceID: String?

    public init(
        id: String,
        name: String,
        countryCode: String,
        bounds: GeoBounds,
        feedSourceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.countryCode = countryCode.uppercased()
        self.bounds = bounds
        self.feedSourceID = feedSourceID
    }

    public var centre: GeoPoint { bounds.center }

    public func contains(_ point: GeoPoint) -> Bool { bounds.contains(point) }

    /// Rough diagonal of the box, used to rank overlapping regions: when a point
    /// falls inside both a metro area and a whole province, the metro area is the
    /// better suggestion.
    public var spanMeters: Double {
        let southWest = GeoPoint(latitude: bounds.minLatitude, longitude: bounds.minLongitude)
        let northEast = GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.maxLongitude)
        return southWest.approximateDistance(to: northEast)
    }

    // MARK: - Known regions

    public static let telAviv = FeedRegion(
        id: "il-tel-aviv",
        name: "Tel Aviv metropolitan area",
        countryCode: "IL",
        bounds: GeoBounds(minLatitude: 31.90, minLongitude: 34.60, maxLatitude: 32.30, maxLongitude: 35.05),
        feedSourceID: "il-mot-tel-aviv"
    )

    public static let jerusalem = FeedRegion(
        id: "il-jerusalem",
        name: "Jerusalem",
        countryCode: "IL",
        bounds: GeoBounds(minLatitude: 31.68, minLongitude: 35.00, maxLatitude: 31.93, maxLongitude: 35.32),
        feedSourceID: "il-mot-jerusalem"
    )

    public static let haifa = FeedRegion(
        id: "il-haifa",
        name: "Haifa and the Krayot",
        countryCode: "IL",
        bounds: GeoBounds(minLatitude: 32.68, minLongitude: 34.87, maxLatitude: 32.98, maxLongitude: 35.20),
        feedSourceID: "il-mot-haifa"
    )

    public static let beerSheva = FeedRegion(
        id: "il-beer-sheva",
        name: "Be'er Sheva and the Negev",
        countryCode: "IL",
        bounds: GeoBounds(minLatitude: 30.95, minLongitude: 34.55, maxLatitude: 31.45, maxLongitude: 35.10),
        feedSourceID: "il-mot-national"
    )

    public static let newYorkCity = FeedRegion(
        id: "us-nyc",
        name: "New York City",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.47, minLongitude: -74.30, maxLatitude: 40.94, maxLongitude: -73.68),
        feedSourceID: "nyc-subway"
    )

    public static let manhattan = FeedRegion(
        id: "us-nyc-manhattan",
        name: "Manhattan",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.68, minLongitude: -74.03, maxLatitude: 40.88, maxLongitude: -73.90),
        feedSourceID: "nyc-bus-manhattan"
    )

    public static let brooklyn = FeedRegion(
        id: "us-nyc-brooklyn",
        name: "Brooklyn",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.55, minLongitude: -74.07, maxLatitude: 40.75, maxLongitude: -73.82),
        feedSourceID: "nyc-bus-brooklyn"
    )

    public static let bronx = FeedRegion(
        id: "us-nyc-bronx",
        name: "The Bronx",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.77, minLongitude: -73.94, maxLatitude: 40.92, maxLongitude: -73.74),
        feedSourceID: "nyc-bus-bronx"
    )

    public static let queens = FeedRegion(
        id: "us-nyc-queens",
        name: "Queens",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.53, minLongitude: -73.97, maxLatitude: 40.81, maxLongitude: -73.69),
        feedSourceID: "nyc-bus-queens"
    )

    public static let statenIsland = FeedRegion(
        id: "us-nyc-staten-island",
        name: "Staten Island",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.48, minLongitude: -74.27, maxLatitude: 40.66, maxLongitude: -74.03),
        feedSourceID: "nyc-bus-staten-island"
    )

    /// Penn Station out to Montauk and Greenport — the LIRR's own extent rather
    /// than an administrative boundary.
    public static let longIsland = FeedRegion(
        id: "us-long-island",
        name: "Long Island",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.57, minLongitude: -74.02, maxLatitude: 41.20, maxLongitude: -71.83),
        feedSourceID: "nyc-lirr"
    )

    /// Grand Central north to Wassaic and Poughkeepsie, east to New Haven.
    public static let lowerHudsonAndConnecticut = FeedRegion(
        id: "us-lower-hudson",
        name: "Lower Hudson Valley and southwest Connecticut",
        countryCode: "US",
        bounds: GeoBounds(minLatitude: 40.70, minLongitude: -74.06, maxLatitude: 41.85, maxLongitude: -72.85),
        feedSourceID: "nyc-metro-north"
    )

    /// Every region the app can offer by name. `containing(_:)` sorts by size, so
    /// the declaration order here is only a tie-break.
    public static let all: [FeedRegion] = [
        telAviv, jerusalem, haifa, beerSheva,
        newYorkCity, manhattan, brooklyn, bronx, queens, statenIsland,
        longIsland, lowerHudsonAndConnecticut,
    ]

    /// Regions whose box contains `point`, tightest first.
    public static func containing(_ point: GeoPoint) -> [FeedRegion] {
        all.filter { $0.contains(point) }.sorted { $0.spanMeters < $1.spanMeters }
    }

    /// The region to preselect for someone standing at `point`.
    ///
    /// Falls back to the nearest region within 150 km rather than returning nil
    /// the moment a user is one kilometre outside a box; the boxes are a
    /// convenience, and being just outside one is not a reason to make the user
    /// draw their own.
    public static func suggested(for point: GeoPoint) -> FeedRegion? {
        if let containing = containing(point).first { return containing }
        var best: FeedRegion?
        var bestDistance = Double.greatestFiniteMagnitude
        for region in all {
            let distance = point.approximateDistance(to: region.centre)
            if distance < bestDistance {
                bestDistance = distance
                best = region
            }
        }
        return bestDistance <= 150_000 ? best : nil
    }

    /// Regions worth offering for a given catalogue entry.
    public static func regions(forFeedSourceID identifier: String) -> [FeedRegion] {
        all.filter { $0.feedSourceID == identifier }
    }

    /// A square-ish box of `radiusKilometres` around a coordinate, for the case
    /// where no named region fits and the user is importing a national feed from
    /// wherever they happen to be.
    public static func box(around point: GeoPoint, radiusKilometres: Double = 35) -> GeoBounds {
        let latitudeSpan = GeoPoint.latitudeDegrees(forMeters: radiusKilometres * 1000)
        let longitudeSpan = point.longitudeDegrees(forMeters: radiusKilometres * 1000)
        return GeoBounds(
            minLatitude: point.latitude - latitudeSpan,
            minLongitude: point.longitude - longitudeSpan,
            maxLatitude: point.latitude + latitudeSpan,
            maxLongitude: point.longitude + longitudeSpan
        )
    }
}
