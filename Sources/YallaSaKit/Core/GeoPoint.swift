import Foundation

/// A WGS84 coordinate. Deliberately independent of CoreLocation so the engine
/// and its tests build on any Apple platform without a location entitlement.
public struct GeoPoint: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Reconstructs a point from the microdegree integers stored in the graph.
    public init(latitudeE6: Int32, longitudeE6: Int32) {
        self.latitude = Double(latitudeE6) / 1_000_000
        self.longitude = Double(longitudeE6) / 1_000_000
    }

    public var latitudeE6: Int32 { GeoPoint.toE6(latitude) }
    public var longitudeE6: Int32 { GeoPoint.toE6(longitude) }

    /// Microdegrees resolve to ~11 cm, far below GTFS stop placement accuracy,
    /// and halve the memory of the two hottest columns in the graph.
    public static func toE6(_ degrees: Double) -> Int32 {
        Int32((degrees * 1_000_000).rounded())
    }

    public var isValid: Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
            && !(latitude == 0 && longitude == 0)
    }

    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance. Used where accuracy matters (fare zones, long legs).
    public func distance(to other: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * GeoPoint.earthRadiusMeters * asin(min(1, sqrt(a)))
    }

    /// Equirectangular approximation. Within 0.5% of great-circle below ~20 km,
    /// and roughly 5x cheaper — this is what the transfer builder and the
    /// nearby-stop scan use, where it runs millions of times.
    public func approximateDistance(to other: GeoPoint) -> Double {
        let meanLat = (latitude + other.latitude) * 0.5 * .pi / 180
        let x = (other.longitude - longitude) * .pi / 180 * cos(meanLat)
        let y = (other.latitude - latitude) * .pi / 180
        return GeoPoint.earthRadiusMeters * (x * x + y * y).squareRoot()
    }

    /// Initial bearing in degrees clockwise from true north, for walking arrows.
    public func bearing(to other: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Degrees of longitude that span `meters` at this latitude. Used to convert
    /// a metre radius into the grid-cell window that must be scanned.
    public func longitudeDegrees(forMeters meters: Double) -> Double {
        let metersPerDegree = 111_320.0 * cos(latitude * .pi / 180)
        guard metersPerDegree > 1 else { return 180 }
        return meters / metersPerDegree
    }

    public static func latitudeDegrees(forMeters meters: Double) -> Double {
        meters / 110_540.0
    }
}

/// An axis-aligned bounding box in degrees.
public struct GeoBounds: Hashable, Sendable, Codable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    /// The identity for `extend(to:)`: inverted infinities, so the first point
    /// added replaces both edges.
    ///
    /// The infinities are why this type encodes itself by hand — see below.
    public static let empty = GeoBounds(
        minLatitude: .infinity, minLongitude: .infinity,
        maxLatitude: -.infinity, maxLongitude: -.infinity
    )

    public var isEmpty: Bool { minLatitude > maxLatitude || minLongitude > maxLongitude }

    // MARK: - Codable
    //
    // Hand-written because `JSONEncoder` refuses to encode a non-finite `Double`
    // and throws rather than writing something wrong. That turns the empty
    // sentinel into a landmine: a graph compiled from a region clip that matched
    // no stops has empty bounds, and writing its metadata — or the feed manifest
    // that embeds it — would fail with "Unable to encode Double.inf directly in
    // JSON", taking down an install that was otherwise fine.
    //
    // So emptiness travels as a flag and the coordinates are simply absent.

    private enum CodingKeys: String, CodingKey {
        case minLatitude, minLongitude, maxLatitude, maxLongitude, isEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .isEmpty) == true {
            self = .empty
            return
        }
        self.minLatitude = try container.decode(Double.self, forKey: .minLatitude)
        self.minLongitude = try container.decode(Double.self, forKey: .minLongitude)
        self.maxLatitude = try container.decode(Double.self, forKey: .maxLatitude)
        self.maxLongitude = try container.decode(Double.self, forKey: .maxLongitude)

        // A file written by some other tool could still carry a non-finite value.
        // Treat that as empty rather than propagating an infinity into the grid
        // arithmetic, where it would silently produce a zero-cell index.
        if !minLatitude.isFinite || !minLongitude.isFinite
            || !maxLatitude.isFinite || !maxLongitude.isFinite {
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard !isEmpty else {
            try container.encode(true, forKey: .isEmpty)
            return
        }
        try container.encode(minLatitude, forKey: .minLatitude)
        try container.encode(minLongitude, forKey: .minLongitude)
        try container.encode(maxLatitude, forKey: .maxLatitude)
        try container.encode(maxLongitude, forKey: .maxLongitude)
    }

    public var center: GeoPoint {
        GeoPoint(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }

    public mutating func extend(to point: GeoPoint) {
        minLatitude = Swift.min(minLatitude, point.latitude)
        minLongitude = Swift.min(minLongitude, point.longitude)
        maxLatitude = Swift.max(maxLatitude, point.latitude)
        maxLongitude = Swift.max(maxLongitude, point.longitude)
    }

    public func contains(_ point: GeoPoint) -> Bool {
        point.latitude >= minLatitude && point.latitude <= maxLatitude
            && point.longitude >= minLongitude && point.longitude <= maxLongitude
    }

    /// Grows the box by a metre margin on all sides.
    public func expanded(byMeters meters: Double) -> GeoBounds {
        let dLat = GeoPoint.latitudeDegrees(forMeters: meters)
        let dLon = center.longitudeDegrees(forMeters: meters)
        return GeoBounds(
            minLatitude: minLatitude - dLat, minLongitude: minLongitude - dLon,
            maxLatitude: maxLatitude + dLat, maxLongitude: maxLongitude + dLon
        )
    }
}
