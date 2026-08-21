import Foundation

/// Live bus positions for Israel, via the Open Bus "Stride" API.
///
/// ## Why this exists at all
///
/// Israel's Ministry of Transport publishes realtime as **SIRI**, not
/// GTFS-Realtime, and its SIRI endpoint requires a registered API key. Both
/// facts put it outside this app's rules: the protobuf decoder cannot read SIRI,
/// and a key is exactly the dependency the project refuses to take. That is why
/// every Israeli entry in `FeedCatalog` shipped with `realtimeTripUpdatesURL`
/// nil, and why the country had no live data.
///
/// The Public Knowledge Workshop (הסדנא לידע ציבורי) ingests that SIRI stream
/// and re-publishes it through an open HTTP+JSON API with **no key and no
/// registration**. That clears both objections, so Israel gets live vehicles.
///
/// ## What it is not
///
/// It is not a trip-update feed. It answers "where is this bus" and not "how
/// late is it", so it does not implement `RealtimeSource` and never reaches the
/// router. Departure boards for Israeli feeds still show scheduled times.
///
/// ## The dependency, stated plainly
///
/// This is a third-party community service, not the agency's own endpoint. It
/// can be slow or down in a way `gtfs.mot.gov.il` is not, and the app must treat
/// an outage as "no dots on the map" rather than an error worth interrupting
/// anyone over. Every failure path here degrades to an empty list or a thrown
/// error the caller is expected to swallow.
public struct StrideVehicleSource: VehiclePositionSource {
    public static let host = "open-bus-stride-api.hasadna.org.il"

    /// Attribution the UI is required to show wherever these positions appear.
    public static let attribution =
        "Live positions: Open Bus / הסדנא לידע ציבורי, from Ministry of Transport SIRI data"

    /// Records older than this are dropped even if the API returns them. A SIRI
    /// fix from twenty minutes ago is not a live position, it is a memory.
    public static let maximumUsableAge: TimeInterval = 15 * 60

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    public func vehicles(
        in bounds: GeoBounds,
        within window: TimeInterval = 180,
        limit: Int = 400
    ) async throws -> [VehiclePosition] {
        guard !bounds.isEmpty else { return [] }

        let end = now()
        let start = end.addingTimeInterval(-max(30, window))
        let url = try requestURL(bounds: bounds, from: start, to: end, limit: limit)

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VehiclePositionError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VehiclePositionError.badStatus(http.statusCode)
        }

        return try Self.positions(fromJSON: data, now: end)
    }

    /// Decode + reduce, split out from the networking so the awkward parts —
    /// duplicate snapshots and corrupt timestamps — are testable without a
    /// server. `vehicles(in:within:limit:)` is a thin wrapper over this.
    static func positions(fromJSON data: Data, now: Date) throws -> [VehiclePosition] {
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw VehiclePositionError.malformedResponse(error.localizedDescription)
        }
        return reduce(rows: rows, now: now)
    }

    // MARK: - Request

    private func requestURL(bounds: GeoBounds, from: Date, to: Date, limit: Int) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/siri_vehicle_locations/list"
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 2000)))),
            URLQueryItem(name: "recorded_at_time_from", value: Self.timestamp(from)),
            URLQueryItem(name: "recorded_at_time_to", value: Self.timestamp(to)),
            URLQueryItem(name: "lat__greater_or_equal", value: Self.number(bounds.minLatitude)),
            URLQueryItem(name: "lat__lower_or_equal", value: Self.number(bounds.maxLatitude)),
            URLQueryItem(name: "lon__greater_or_equal", value: Self.number(bounds.minLongitude)),
            URLQueryItem(name: "lon__lower_or_equal", value: Self.number(bounds.maxLongitude)),
            // Newest first, so truncation by `limit` drops the stalest fixes
            // rather than an arbitrary slice.
            URLQueryItem(name: "order_by", value: "recorded_at_time desc"),
        ]
        guard let url = components.url else {
            throw VehiclePositionError.malformedResponse("could not build a request URL")
        }
        return url
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    // MARK: - Response

    /// Only the fields we use. The endpoint returns roughly twenty columns of
    /// pipeline bookkeeping (`siri_snapshot_id`, `siri_ride_stop_id`, …) that
    /// describe how the data was collected rather than where the bus is.
    struct Row: Decodable {
        var lat: Double?
        var lon: Double?
        var bearing: Double?
        var velocity: Double?
        var recordedAtTime: String?
        var lineRef: Int?
        var operatorRef: Int?
        var vehicleRef: String?
        var journeyRef: String?

        enum CodingKeys: String, CodingKey {
            case lat, lon, bearing, velocity
            case recordedAtTime = "recorded_at_time"
            case lineRef = "siri_route__line_ref"
            case operatorRef = "siri_route__operator_ref"
            case vehicleRef = "siri_ride__vehicle_ref"
            case journeyRef = "siri_ride__journey_ref"
        }
    }

    /// Turns raw rows into at most one position per vehicle, newest first.
    ///
    /// Two defences matter here, and both are against real data this endpoint
    /// actually serves:
    ///
    /// 1. **Duplicates.** The API returns one row per SIRI *snapshot*, so a
    ///    vehicle that reported four times inside the window appears four times.
    ///    Drawing all four puts a smear of markers along the road.
    /// 2. **Impossible timestamps.** Some rows carry `recorded_at_time` in 2038
    ///    — the 32-bit epoch ceiling leaking through the pipeline. Sorted
    ///    "newest first" those rows come back *first*, so a naive reader shows
    ///    a decade-old snapshot as the freshest thing on the map.
    static func reduce(rows: [Row], now: Date) -> [VehiclePosition] {
        var newest: [String: VehiclePosition] = [:]
        newest.reserveCapacity(rows.count)

        for row in rows {
            guard let lat = row.lat, let lon = row.lon,
                  let lineRef = row.lineRef,
                  let stamp = row.recordedAtTime,
                  let recordedAt = parseTimestamp(stamp)
            else { continue }

            let point = GeoPoint(latitude: lat, longitude: lon)
            guard point.isValid else { continue }

            // A fix from the future is corrupt by definition; a small negative
            // age is just clock skew between us and the server, so allow a
            // minute of it before rejecting.
            let age = now.timeIntervalSince(recordedAt)
            guard age > -60, age <= maximumUsableAge else { continue }

            let vehicleID = row.vehicleRef.flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(lineRef)-\(lat),\(lon)"

            let position = VehiclePosition(
                id: vehicleID,
                point: point,
                // A bearing is only meaningful while moving. Feeds keep the last
                // heading when a vehicle stops, which points the arrow down
                // whatever road it was on before it parked.
                bearingDegrees: (row.velocity ?? 0) > 1 ? row.bearing : nil,
                speedKilometresPerHour: row.velocity,
                recordedAt: recordedAt,
                lineReference: String(lineRef),
                operatorReference: row.operatorRef.map(String.init),
                journeyReference: row.journeyRef
            )

            if let existing = newest[vehicleID], existing.recordedAt >= recordedAt { continue }
            newest[vehicleID] = position
        }

        return newest.values.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// The API mixes `+00:00` and `Z` offsets and sometimes omits fractional
    /// seconds, so both ISO 8601 shapes have to be tried.
    static func parseTimestamp(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
