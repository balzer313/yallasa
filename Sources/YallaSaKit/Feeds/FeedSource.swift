import Foundation

/// Where a transit feed comes from, and everything needed to fetch it without
/// asking the user a single question.
///
/// A source is data, not code: it round-trips through the manifest so an
/// installed feed can be refreshed months later even if the bundled catalogue has
/// moved on, and so a user-supplied URL is a first-class citizen rather than a
/// special case. That is also why `bounds` and `defaultBoundingBox` are separate.
/// `bounds` says *where this feed is useful* — it drives "which feed should I
/// offer this user" — while `defaultBoundingBox` says *what to keep when
/// compiling*. For a city feed they are the same box. For a national feed like
/// Israel's, `bounds` covers the country and `defaultBoundingBox` covers one
/// metro area, which is the difference between a 1 GB import that a phone cannot
/// finish and a 60 MB one that takes a couple of minutes.
public struct FeedSource: Codable, Hashable, Sendable, Identifiable {
    /// Stable, filesystem-safe-ish identifier. Used as the manifest key and as
    /// the stem of the archive and graph file names, so changing it for an
    /// existing feed orphans its files rather than upgrading them.
    public var id: String
    public var name: String
    /// Human-readable area, e.g. "Tel Aviv metropolitan area".
    public var region: String
    /// ISO 3166-1 alpha-2, uppercased. Only used for grouping and flags.
    public var countryCode: String
    /// The GTFS static archive.
    public var staticURL: URL
    /// GTFS-realtime `TripUpdate` feed, when one is available without a key.
    public var realtimeTripUpdatesURL: URL?
    /// GTFS-realtime `Alert` feed, when one is available without a key.
    public var realtimeAlertsURL: URL?
    /// Applied to every request for this source. Some publishers reject the
    /// default `URLSession` user agent outright.
    public var requestHeaders: [String: String]
    /// Shown in Settings. Most open-data licences require it, and it is the only
    /// honest answer to "where did this timetable come from".
    public var attribution: String
    public var licenseURL: URL?
    /// Compressed size, roughly. Only used to show a sensible number before the
    /// server has told us `Content-Length`, so being 30% out is harmless.
    public var approximateDownloadMegabytes: Int
    /// Where the feed has service. Drives `FeedCatalog.nearest(to:)`.
    public var bounds: GeoBounds?
    /// The clip box applied at import when the caller does not supply one.
    public var defaultBoundingBox: GeoBounds?
    /// A keyless source of live vehicle positions, where one exists.
    ///
    /// Deliberately not one of the two realtime URLs above: those are GTFS-RT
    /// protobuf endpoints answering "how late is this trip", and this answers
    /// "where is this bus" over a different protocol. Israel publishes SIRI
    /// behind an API key, so its `realtimeTripUpdatesURL` stays nil while this
    /// is set.
    public var vehiclePositions: VehiclePositionService?

    public init(
        id: String,
        name: String,
        region: String,
        countryCode: String,
        staticURL: URL,
        realtimeTripUpdatesURL: URL? = nil,
        realtimeAlertsURL: URL? = nil,
        requestHeaders: [String: String] = [:],
        attribution: String,
        licenseURL: URL? = nil,
        approximateDownloadMegabytes: Int = 0,
        bounds: GeoBounds? = nil,
        defaultBoundingBox: GeoBounds? = nil,
        vehiclePositions: VehiclePositionService? = nil
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.countryCode = countryCode
        self.staticURL = staticURL
        self.realtimeTripUpdatesURL = realtimeTripUpdatesURL
        self.realtimeAlertsURL = realtimeAlertsURL
        self.requestHeaders = requestHeaders
        self.attribution = attribution
        self.licenseURL = licenseURL
        self.approximateDownloadMegabytes = approximateDownloadMegabytes
        self.bounds = bounds
        self.defaultBoundingBox = defaultBoundingBox
        self.vehiclePositions = vehiclePositions
    }

    // MARK: - Derived

    /// Centre of the served area, used for "which feed is nearest".
    public var centre: GeoPoint? {
        guard let bounds, !bounds.isEmpty else { return nil }
        return bounds.center
    }

    public var hasRealtime: Bool {
        realtimeTripUpdatesURL != nil || realtimeAlertsURL != nil
    }

    /// True when the map can draw moving vehicles for this feed.
    ///
    /// Independent of `hasRealtime`, and Israel is exactly why: it has live
    /// positions but no trip updates, so its map moves while its departure
    /// boards stay scheduled. Telling the rider which of the two they are
    /// looking at is the UI's job.
    public var hasLiveVehicles: Bool { vehiclePositions != nil }

    /// A byte estimate for progress reporting before the server answers.
    public var estimatedDownloadBytes: Int64 {
        Int64(max(0, approximateDownloadMegabytes)) * 1_048_576
    }

    /// True when the feed covers far more ground than one rider needs. The UI
    /// uses this to insist on a region before starting a multi-hundred-megabyte
    /// import that would otherwise be abandoned halfway.
    public var needsRegionSelection: Bool {
        guard let bounds, !bounds.isEmpty else { return false }
        let latitudeSpan = bounds.maxLatitude - bounds.minLatitude
        let longitudeSpan = bounds.maxLongitude - bounds.minLongitude
        return approximateDownloadMegabytes >= 60 || latitudeSpan > 2.5 || longitudeSpan > 2.5
    }

    /// A source for a URL the user typed in. The catalogue will always be
    /// incomplete, and a feed we have never heard of should be one paste away
    /// rather than impossible.
    public static func custom(
        staticURL: URL,
        name: String,
        region: String = "",
        countryCode: String = "",
        boundingBox: GeoBounds? = nil
    ) -> FeedSource {
        FeedSource(
            id: "custom-" + fingerprint(of: staticURL.absoluteString),
            name: name.isEmpty ? staticURL.lastPathComponent : name,
            region: region,
            countryCode: countryCode.uppercased(),
            staticURL: staticURL,
            attribution: "User-supplied feed",
            approximateDownloadMegabytes: 0,
            bounds: boundingBox,
            defaultBoundingBox: boundingBox
        )
    }

    /// A short, stable, filename-safe digest of a string. FNV-1a rather than a
    /// cryptographic hash because this only needs to avoid collisions between the
    /// handful of URLs one user pastes, and `Hasher` is explicitly not stable
    /// across launches — which would orphan every custom feed on relaunch.
    private static func fingerprint(of value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    // MARK: - Codable
    //
    // Written out by hand so a manifest produced by an older build still decodes
    // after a field is added. The synthesised initialiser would reject it.

    private enum CodingKeys: String, CodingKey {
        case id, name, region, countryCode, staticURL
        case realtimeTripUpdatesURL, realtimeAlertsURL
        case requestHeaders, attribution, licenseURL
        case approximateDownloadMegabytes, bounds, defaultBoundingBox
        case vehiclePositions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.region = try container.decodeIfPresent(String.self, forKey: .region) ?? ""
        self.countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode) ?? ""
        self.staticURL = try container.decode(URL.self, forKey: .staticURL)
        self.realtimeTripUpdatesURL = try container.decodeIfPresent(URL.self, forKey: .realtimeTripUpdatesURL)
        self.realtimeAlertsURL = try container.decodeIfPresent(URL.self, forKey: .realtimeAlertsURL)
        self.requestHeaders = try container.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:]
        self.attribution = try container.decodeIfPresent(String.self, forKey: .attribution) ?? ""
        self.licenseURL = try container.decodeIfPresent(URL.self, forKey: .licenseURL)
        self.approximateDownloadMegabytes =
            try container.decodeIfPresent(Int.self, forKey: .approximateDownloadMegabytes) ?? 0
        self.bounds = try container.decodeIfPresent(GeoBounds.self, forKey: .bounds)
        self.defaultBoundingBox = try container.decodeIfPresent(GeoBounds.self, forKey: .defaultBoundingBox)
        // Unknown or newer values decode as nil rather than throwing: a manifest
        // written by a later build must not make an installed feed unreadable.
        self.vehiclePositions =
            try? container.decodeIfPresent(VehiclePositionService.self, forKey: .vehiclePositions)
    }
}
