import Foundation

// MARK: - Field access

/// Column access that tolerates a column the feed never declared.
///
/// Optional GTFS columns are routinely absent, so every read goes through a
/// resolved index that may be `-1`. Funnelling the guard through here keeps the
/// readers below free of `if column >= 0` noise and means a missing column can
/// never index past the row.
enum GTFSField {
    @inline(__always)
    static func bytes(_ row: CSVRow, _ column: Int) -> UnsafeBufferPointer<UInt8> {
        guard column >= 0 else { return UnsafeBufferPointer(start: nil, count: 0) }
        return row.bytes(column)
    }

    @inline(__always)
    static func string(_ row: CSVRow, _ column: Int) -> String {
        guard column >= 0 else { return "" }
        return row.string(column)
    }

    @inline(__always)
    static func integer(_ row: CSVRow, _ column: Int) -> Int? {
        guard column >= 0 else { return nil }
        return row.int(column)
    }

    @inline(__always)
    static func decimal(_ row: CSVRow, _ column: Int) -> Double? {
        guard column >= 0 else { return nil }
        return row.double(column)
    }

    @inline(__always)
    static func isBlank(_ row: CSVRow, _ column: Int) -> Bool {
        guard column >= 0 else { return true }
        return row.isEmpty(column)
    }

    /// Byte-level twin of `parseGTFSTime`.
    ///
    /// `stop_times.txt` is the one table where materialising a `String` per field
    /// would dominate the whole import: a metro feed has two of these per row and
    /// millions of rows. Values at or above 86400 are returned unchanged — that is
    /// how GTFS spells "after midnight, still yesterday's service day".
    static func time(_ bytes: UnsafeBufferPointer<UInt8>) -> ServiceSeconds? {
        var field = 0
        var digits = 0
        var value = 0
        var hours = 0
        var minutes = 0
        for byte in bytes {
            if byte == UInt8(ascii: ":") {
                guard digits > 0, field < 2 else { return nil }
                if field == 0 { hours = value } else { minutes = value }
                field += 1
                digits = 0
                value = 0
            } else if byte >= 48, byte <= 57 {
                value = value * 10 + Int(byte - 48)
                digits += 1
                if digits > 3 { return nil }
            } else if byte == UInt8(ascii: " ") {
                continue
            } else {
                return nil
            }
        }
        guard field == 2, digits > 0 else { return nil }
        let seconds = value
        guard minutes < 60, seconds < 60, hours < 240 else { return nil }
        return ServiceSeconds(hours * 3600 + minutes * 60 + seconds)
    }

    /// `RRGGBB`, with or without the leading `#` some feeds add. Nil for anything
    /// else, so the caller can store the "fall back to the mode default" sentinel
    /// rather than a black badge.
    static func color(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        var value: UInt32 = 0
        var digits = 0
        for byte in bytes {
            if byte == UInt8(ascii: "#") || byte == UInt8(ascii: " ") { continue }
            let nibble: UInt32
            switch byte {
            case 48...57: nibble = UInt32(byte - 48)
            case 65...70: nibble = UInt32(byte - 55)
            case 97...102: nibble = UInt32(byte - 87)
            default: return nil
            }
            value = (value << 4) | nibble
            digits += 1
            if digits > 6 { return nil }
        }
        guard digits == 6 else { return nil }
        return value
    }
}

// MARK: - Identifier lookup

/// Maps raw GTFS id bytes onto a dense index without allocating a `String`.
///
/// `stop_times.txt` resolves two ids per row. Going through `String` would cost
/// two allocations and two hashes per row — tens of millions of them on a metro
/// feed — for values that are already sitting in the CSV buffer. Keys are stored
/// once, hashed with FNV-1a, and compared byte-wise on collision.
struct GTFSIdentifierMap {
    private var keys: [[UInt8]] = []
    private var values: [Int32] = []
    private var buckets: [UInt64: [Int32]] = [:]

    var count: Int { keys.count }

    mutating func insert(_ bytes: UnsafeBufferPointer<UInt8>, value: Int32) {
        guard bytes.count > 0 else { return }
        let key = Array(bytes)
        let slot = Int32(keys.count)
        keys.append(key)
        values.append(value)
        buckets[GTFSIdentifierMap.hash(key), default: []].append(slot)
    }

    func value(for bytes: UnsafeBufferPointer<UInt8>) -> Int32? {
        guard bytes.count > 0 else { return nil }
        guard let slots = buckets[GTFSIdentifierMap.hash(bytes)] else { return nil }
        for slot in slots {
            let key = keys[Int(slot)]
            guard key.count == bytes.count else { continue }
            var equal = true
            for offset in 0..<key.count where key[offset] != bytes[offset] {
                equal = false
                break
            }
            if equal { return values[Int(slot)] }
        }
        return nil
    }

    /// Rewrites every stored value through `mapping`. The importer reorders stops
    /// spatially after reading them, and this is how the id table follows.
    mutating func remapValues(_ mapping: [Int32]) {
        for index in 0..<values.count {
            let old = Int(values[index])
            values[index] = (old >= 0 && old < mapping.count) ? mapping[old] : noIndex
        }
    }

    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    private static func hash(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }
}

// MARK: - Intermediate tables
//
// Every table below is a structure of arrays of integers and string-blob
// offsets. Nothing here holds a `String` per row: the whole point of the import
// pipeline is that the only text in memory is the interned blob.

struct GTFSAgencyTable {
    var identifierRefs: [UInt32] = []
    var nameRefs: [UInt32] = []
    var urlRefs: [UInt32] = []
    var timeZoneRefs: [UInt32] = []
    var indexByIdentifierRef: [UInt32: AgencyIndex] = [:]
    /// The zone every service time in the graph is measured against. GTFS
    /// requires all agencies in one feed to share it, so the first wins.
    var timeZoneIdentifier: String = ""

    var count: Int { identifierRefs.count }
}

struct GTFSStopTable {
    var identifierRefs: [UInt32] = []
    var nameRefs: [UInt32] = []
    var codeRefs: [UInt32] = []
    var platformRefs: [UInt32] = []
    var parentRefs: [UInt32] = []
    var latitudes: [Double] = []
    var longitudes: [Double] = []
    /// Bits 0-1 `AccessibilityFlag`, bit 2 set for `location_type = 1`.
    var flags: [UInt8] = []
    var identifierMap = GTFSIdentifierMap()

    var count: Int { identifierRefs.count }
}

struct GTFSRouteTable {
    var identifierRefs: [UInt32] = []
    var shortNameRefs: [UInt32] = []
    var longNameRefs: [UInt32] = []
    var descriptionRefs: [UInt32] = []
    var types: [UInt16] = []
    var colors: [UInt32] = []
    var textColors: [UInt32] = []
    var agencies: [AgencyIndex] = []
    var indexByIdentifierRef: [UInt32: RouteIndex] = [:]

    var count: Int { identifierRefs.count }
}

struct GTFSTripTable {
    var routeIndices: [RouteIndex] = []
    var serviceIndices: [ServiceIndex] = []
    var identifierRefs: [UInt32] = []
    var headsignRefs: [UInt32] = []
    var shortNameRefs: [UInt32] = []
    var directions: [UInt8] = []
    /// Bits 0-1 wheelchair `AccessibilityFlag`, bits 2-3 bicycles.
    var flags: [UInt8] = []
    var indexByIdentifierRef: [UInt32: TripIndex] = [:]
    var identifierMap = GTFSIdentifierMap()

    var count: Int { routeIndices.count }
}

struct GTFSCalendarRow {
    var serviceRef: UInt32
    /// Bit 0 Monday … bit 6 Sunday, matching `ServiceDate.weekdayIndex`.
    var weekdayMask: UInt8
    var startDate: ServiceDate
    var endDate: ServiceDate
}

struct GTFSCalendarDateRow {
    var serviceRef: UInt32
    var date: ServiceDate
    var isAdded: Bool
}

struct GTFSTransferRow {
    var fromStopRef: UInt32
    var toStopRef: UInt32
    var type: UInt8
    /// Negative when the feed declares no minimum.
    var minimumSeconds: Int32
}

struct GTFSFrequencyRow {
    var tripRef: UInt32
    var startTime: ServiceSeconds
    var endTime: ServiceSeconds
    var headwaySeconds: Int32
    var exactTimes: Bool
}

/// Every `stop_times.txt` row, as parallel integer columns.
///
/// GTFS does not guarantee the file is grouped by trip, and a comparison sort of
/// millions of rows to make it so is wasteful. Holding the rows flat lets the
/// importer group them with a counting sort in one linear pass, which handles the
/// pathological case at the cost of the grouped one.
struct GTFSStopTimeRows {
    var trips: [Int32] = []
    var stops: [Int32] = []
    var sequences: [Int32] = []
    var arrivals: [ServiceSeconds] = []
    var departures: [ServiceSeconds] = []
    var pickups: [UInt8] = []
    var dropOffs: [UInt8] = []

    var count: Int { trips.count }
}

// MARK: - Readers

enum GTFSTables {

    static func readAgencies(_ reader: inout CSVReader, strings: inout StringTableBuilder) -> GTFSAgencyTable {
        var table = GTFSAgencyTable()
        let idColumn = reader.columnIndex("agency_id") ?? -1
        let nameColumn = reader.columnIndex("agency_name") ?? -1
        let urlColumn = reader.columnIndex("agency_url") ?? -1
        let zoneColumn = reader.columnIndex("agency_timezone") ?? -1

        while let row = reader.next() {
            let identifierRef = strings.intern(utf8: GTFSField.bytes(row, idColumn))
            let zone = GTFSField.string(row, zoneColumn)
            if table.timeZoneIdentifier.isEmpty, !zone.isEmpty {
                table.timeZoneIdentifier = zone
            }
            let index = AgencyIndex(table.identifierRefs.count)
            table.identifierRefs.append(identifierRef)
            table.nameRefs.append(strings.intern(utf8: GTFSField.bytes(row, nameColumn)))
            table.urlRefs.append(strings.intern(utf8: GTFSField.bytes(row, urlColumn)))
            table.timeZoneRefs.append(strings.intern(zone))
            if identifierRef != 0 { table.indexByIdentifierRef[identifierRef] = index }
        }
        return table
    }

    static func readStops(
        _ reader: inout CSVReader,
        strings: inout StringTableBuilder,
        report: inout GraphMetadata.ImportReport,
        boundingBox: GeoBounds?
    ) -> GTFSStopTable {
        var table = GTFSStopTable()
        let idColumn = reader.columnIndex("stop_id") ?? -1
        let nameColumn = reader.columnIndex("stop_name") ?? -1
        let codeColumn = reader.columnIndex("stop_code") ?? -1
        let platformColumn = reader.columnIndex("platform_code") ?? -1
        let latitudeColumn = reader.columnIndex("stop_lat") ?? -1
        let longitudeColumn = reader.columnIndex("stop_lon") ?? -1
        let locationColumn = reader.columnIndex("location_type") ?? -1
        let parentColumn = reader.columnIndex("parent_station") ?? -1
        let accessColumn = reader.columnIndex("wheelchair_boarding") ?? -1

        while let row = reader.next() {
            // 2/3/4 are entrances, generic pathway nodes and boarding areas. No
            // vehicle ever calls at one, so carrying them would only inflate the
            // spatial grid.
            let locationType = GTFSField.integer(row, locationColumn) ?? 0
            if locationType >= 2 { continue }

            guard let latitude = GTFSField.decimal(row, latitudeColumn),
                  let longitude = GTFSField.decimal(row, longitudeColumn)
            else {
                report.droppedStopsMissingCoordinate += 1
                continue
            }
            let point = GeoPoint(latitude: latitude, longitude: longitude)
            guard point.isValid else {
                report.droppedStopsMissingCoordinate += 1
                continue
            }
            if let boundingBox, !boundingBox.contains(point) { continue }

            var flags = AccessibilityFlag(gtfs: GTFSField.integer(row, accessColumn) ?? 0).rawValue & 0b11
            if locationType == 1 { flags |= 0b100 }

            let identifierBytes = GTFSField.bytes(row, idColumn)
            table.identifierMap.insert(identifierBytes, value: Int32(table.identifierRefs.count))
            table.identifierRefs.append(strings.intern(utf8: identifierBytes))
            table.nameRefs.append(strings.intern(utf8: GTFSField.bytes(row, nameColumn)))
            table.codeRefs.append(strings.intern(utf8: GTFSField.bytes(row, codeColumn)))
            table.platformRefs.append(strings.intern(utf8: GTFSField.bytes(row, platformColumn)))
            table.parentRefs.append(strings.intern(utf8: GTFSField.bytes(row, parentColumn)))
            table.latitudes.append(latitude)
            table.longitudes.append(longitude)
            table.flags.append(flags)
        }
        return table
    }

    static func readRoutes(
        _ reader: inout CSVReader,
        strings: inout StringTableBuilder,
        agencies: GTFSAgencyTable
    ) -> GTFSRouteTable {
        var table = GTFSRouteTable()
        let idColumn = reader.columnIndex("route_id") ?? -1
        let agencyColumn = reader.columnIndex("agency_id") ?? -1
        let shortColumn = reader.columnIndex("route_short_name") ?? -1
        let longColumn = reader.columnIndex("route_long_name") ?? -1
        let descriptionColumn = reader.columnIndex("route_desc") ?? -1
        let typeColumn = reader.columnIndex("route_type") ?? -1
        let colorColumn = reader.columnIndex("route_color") ?? -1
        let textColorColumn = reader.columnIndex("route_text_color") ?? -1

        while let row = reader.next() {
            let identifierRef = strings.intern(utf8: GTFSField.bytes(row, idColumn))
            let agencyRef = strings.intern(utf8: GTFSField.bytes(row, agencyColumn))
            // A single-agency feed is allowed to omit agency_id everywhere.
            var agency = agencies.indexByIdentifierRef[agencyRef] ?? noIndex
            if agency == noIndex, agencies.count == 1 { agency = 0 }

            let rawType = GTFSField.integer(row, typeColumn) ?? 3
            let index = RouteIndex(table.identifierRefs.count)

            table.identifierRefs.append(identifierRef)
            table.shortNameRefs.append(strings.intern(utf8: GTFSField.bytes(row, shortColumn)))
            table.longNameRefs.append(strings.intern(utf8: GTFSField.bytes(row, longColumn)))
            table.descriptionRefs.append(strings.intern(utf8: GTFSField.bytes(row, descriptionColumn)))
            table.types.append(UInt16(clamping: rawType))
            table.colors.append(GTFSField.color(GTFSField.bytes(row, colorColumn)) ?? UInt32.max)
            table.textColors.append(GTFSField.color(GTFSField.bytes(row, textColorColumn)) ?? UInt32.max)
            table.agencies.append(agency)
            if identifierRef != 0 { table.indexByIdentifierRef[identifierRef] = index }
        }
        return table
    }

    static func readTrips(
        _ reader: inout CSVReader,
        strings: inout StringTableBuilder,
        report: inout GraphMetadata.ImportReport,
        routeIndexByRef: [UInt32: RouteIndex],
        serviceIndexByRef: [UInt32: ServiceIndex]
    ) -> GTFSTripTable {
        var table = GTFSTripTable()
        let idColumn = reader.columnIndex("trip_id") ?? -1
        let routeColumn = reader.columnIndex("route_id") ?? -1
        let serviceColumn = reader.columnIndex("service_id") ?? -1
        let headsignColumn = reader.columnIndex("trip_headsign") ?? -1
        let shortNameColumn = reader.columnIndex("trip_short_name") ?? -1
        let directionColumn = reader.columnIndex("direction_id") ?? -1
        let accessColumn = reader.columnIndex("wheelchair_accessible") ?? -1
        let bicycleColumn = reader.columnIndex("bikes_allowed") ?? -1

        while let row = reader.next() {
            let routeRef = strings.intern(utf8: GTFSField.bytes(row, routeColumn))
            guard let route = routeIndexByRef[routeRef] else {
                report.droppedTripsUnknownRoute += 1
                continue
            }
            let serviceRef = strings.intern(utf8: GTFSField.bytes(row, serviceColumn))
            guard let service = serviceIndexByRef[serviceRef] else {
                report.droppedTripsUnknownService += 1
                continue
            }

            let wheelchair = AccessibilityFlag(gtfs: GTFSField.integer(row, accessColumn) ?? 0).rawValue & 0b11
            let bicycles = AccessibilityFlag(gtfs: GTFSField.integer(row, bicycleColumn) ?? 0).rawValue & 0b11

            let identifierBytes = GTFSField.bytes(row, idColumn)
            let identifierRef = strings.intern(utf8: identifierBytes)
            let index = TripIndex(table.routeIndices.count)

            table.identifierMap.insert(identifierBytes, value: index)
            table.routeIndices.append(route)
            table.serviceIndices.append(service)
            table.identifierRefs.append(identifierRef)
            table.headsignRefs.append(strings.intern(utf8: GTFSField.bytes(row, headsignColumn)))
            table.shortNameRefs.append(strings.intern(utf8: GTFSField.bytes(row, shortNameColumn)))
            table.directions.append(UInt8(clamping: GTFSField.integer(row, directionColumn) ?? 0))
            table.flags.append(wheelchair | (bicycles << 2))
            if identifierRef != 0 { table.indexByIdentifierRef[identifierRef] = index }
        }
        return table
    }

    static func readCalendar(_ reader: inout CSVReader, strings: inout StringTableBuilder) -> [GTFSCalendarRow] {
        var rows: [GTFSCalendarRow] = []
        let serviceColumn = reader.columnIndex("service_id") ?? -1
        let startColumn = reader.columnIndex("start_date") ?? -1
        let endColumn = reader.columnIndex("end_date") ?? -1
        let weekdayColumns = [
            reader.columnIndex("monday") ?? -1,
            reader.columnIndex("tuesday") ?? -1,
            reader.columnIndex("wednesday") ?? -1,
            reader.columnIndex("thursday") ?? -1,
            reader.columnIndex("friday") ?? -1,
            reader.columnIndex("saturday") ?? -1,
            reader.columnIndex("sunday") ?? -1,
        ]

        while let row = reader.next() {
            guard let start = ServiceDate(gtfs: GTFSField.string(row, startColumn)),
                  let end = ServiceDate(gtfs: GTFSField.string(row, endColumn)),
                  start <= end
            else { continue }

            var mask: UInt8 = 0
            for weekday in 0..<7 where (GTFSField.integer(row, weekdayColumns[weekday]) ?? 0) == 1 {
                mask |= UInt8(1) << UInt8(weekday)
            }
            rows.append(
                GTFSCalendarRow(
                    serviceRef: strings.intern(utf8: GTFSField.bytes(row, serviceColumn)),
                    weekdayMask: mask,
                    startDate: start,
                    endDate: end
                )
            )
        }
        return rows
    }

    static func readCalendarDates(
        _ reader: inout CSVReader,
        strings: inout StringTableBuilder
    ) -> [GTFSCalendarDateRow] {
        var rows: [GTFSCalendarDateRow] = []
        let serviceColumn = reader.columnIndex("service_id") ?? -1
        let dateColumn = reader.columnIndex("date") ?? -1
        let typeColumn = reader.columnIndex("exception_type") ?? -1

        while let row = reader.next() {
            guard let date = ServiceDate(gtfs: GTFSField.string(row, dateColumn)) else { continue }
            let exception = GTFSField.integer(row, typeColumn) ?? 1
            guard exception == 1 || exception == 2 else { continue }
            rows.append(
                GTFSCalendarDateRow(
                    serviceRef: strings.intern(utf8: GTFSField.bytes(row, serviceColumn)),
                    date: date,
                    isAdded: exception == 1
                )
            )
        }
        return rows
    }

    static func readTransfers(_ reader: inout CSVReader, strings: inout StringTableBuilder) -> [GTFSTransferRow] {
        var rows: [GTFSTransferRow] = []
        let fromColumn = reader.columnIndex("from_stop_id") ?? -1
        let toColumn = reader.columnIndex("to_stop_id") ?? -1
        let typeColumn = reader.columnIndex("transfer_type") ?? -1
        let minimumColumn = reader.columnIndex("min_transfer_time") ?? -1

        while let row = reader.next() {
            let type = GTFSField.integer(row, typeColumn) ?? 0
            let minimum = GTFSField.integer(row, minimumColumn)
            rows.append(
                GTFSTransferRow(
                    fromStopRef: strings.intern(utf8: GTFSField.bytes(row, fromColumn)),
                    toStopRef: strings.intern(utf8: GTFSField.bytes(row, toColumn)),
                    type: UInt8(clamping: type),
                    minimumSeconds: minimum.map { Int32(clamping: $0) } ?? -1
                )
            )
        }
        return rows
    }

    static func readFrequencies(_ reader: inout CSVReader, strings: inout StringTableBuilder) -> [GTFSFrequencyRow] {
        var rows: [GTFSFrequencyRow] = []
        let tripColumn = reader.columnIndex("trip_id") ?? -1
        let startColumn = reader.columnIndex("start_time") ?? -1
        let endColumn = reader.columnIndex("end_time") ?? -1
        let headwayColumn = reader.columnIndex("headway_secs") ?? -1
        let exactColumn = reader.columnIndex("exact_times") ?? -1

        while let row = reader.next() {
            guard let start = GTFSField.time(GTFSField.bytes(row, startColumn)),
                  let end = GTFSField.time(GTFSField.bytes(row, endColumn)),
                  let headway = GTFSField.integer(row, headwayColumn), headway > 0
            else { continue }
            rows.append(
                GTFSFrequencyRow(
                    tripRef: strings.intern(utf8: GTFSField.bytes(row, tripColumn)),
                    startTime: start,
                    endTime: end,
                    headwaySeconds: Int32(clamping: headway),
                    exactTimes: (GTFSField.integer(row, exactColumn) ?? 0) == 1
                )
            )
        }
        return rows
    }

    static func readFeedVersion(_ reader: inout CSVReader) -> String {
        let versionColumn = reader.columnIndex("feed_version") ?? -1
        while let row = reader.next() {
            let value = GTFSField.string(row, versionColumn)
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// Streams `stop_times.txt` into flat columns.
    ///
    /// Rows for trips the importer already dropped are skipped without a counter:
    /// the trip was counted once when it was dropped, and counting each of its
    /// stop times again would make the report read as if the feed were far more
    /// broken than it is.
    static func readStopTimes(
        _ reader: inout CSVReader,
        report: inout GraphMetadata.ImportReport,
        trips: GTFSIdentifierMap,
        stops: GTFSIdentifierMap,
        into rows: inout GTFSStopTimeRows,
        progress: (Double) -> Void
    ) {
        let tripColumn = reader.columnIndex("trip_id") ?? -1
        let stopColumn = reader.columnIndex("stop_id") ?? -1
        let arrivalColumn = reader.columnIndex("arrival_time") ?? -1
        let departureColumn = reader.columnIndex("departure_time") ?? -1
        let sequenceColumn = reader.columnIndex("stop_sequence") ?? -1
        let pickupColumn = reader.columnIndex("pickup_type") ?? -1
        let dropOffColumn = reader.columnIndex("drop_off_type") ?? -1

        // Real feeds group by trip, so the previous row's trip id is almost always
        // this row's too. Caching it turns the per-row hash lookup into a memcmp.
        var cachedTripKey: [UInt8] = []
        var cachedTripIndex: Int32 = noIndex
        var hasCachedTrip = false
        var rowsSinceProgress = 0

        while let row = reader.next() {
            rowsSinceProgress += 1
            if rowsSinceProgress >= 100_000 {
                rowsSinceProgress = 0
                progress(reader.approximateProgress)
            }

            let tripBytes = GTFSField.bytes(row, tripColumn)
            var tripIndex: Int32 = noIndex
            var matchesCache = false
            if hasCachedTrip, cachedTripKey.count == tripBytes.count {
                matchesCache = true
                for offset in 0..<cachedTripKey.count where cachedTripKey[offset] != tripBytes[offset] {
                    matchesCache = false
                    break
                }
            }
            if matchesCache {
                tripIndex = cachedTripIndex
            } else {
                tripIndex = trips.value(for: tripBytes) ?? noIndex
                cachedTripKey = Array(tripBytes)
                cachedTripIndex = tripIndex
                hasCachedTrip = true
            }
            guard tripIndex >= 0 else { continue }

            guard let stopIndex = stops.value(for: GTFSField.bytes(row, stopColumn)), stopIndex >= 0 else {
                report.droppedStopTimesUnknownStop += 1
                continue
            }

            var arrival: ServiceSeconds = noTime
            let arrivalBytes = GTFSField.bytes(row, arrivalColumn)
            if arrivalBytes.count > 0 {
                if let parsed = GTFSField.time(arrivalBytes) {
                    arrival = parsed
                } else {
                    report.droppedStopTimesUnparsableTime += 1
                }
            }
            var departure: ServiceSeconds = noTime
            let departureBytes = GTFSField.bytes(row, departureColumn)
            if departureBytes.count > 0 {
                if let parsed = GTFSField.time(departureBytes) {
                    departure = parsed
                } else {
                    report.droppedStopTimesUnparsableTime += 1
                }
            }

            let sequence = GTFSField.integer(row, sequenceColumn).map { Int32(clamping: $0) }
                ?? Int32(clamping: rows.count)

            rows.trips.append(tripIndex)
            rows.stops.append(stopIndex)
            rows.sequences.append(sequence)
            rows.arrivals.append(arrival)
            rows.departures.append(departure)
            rows.pickups.append(StopServiceAvailability(gtfs: GTFSField.integer(row, pickupColumn) ?? 0).rawValue)
            rows.dropOffs.append(StopServiceAvailability(gtfs: GTFSField.integer(row, dropOffColumn) ?? 0).rawValue)
        }
        progress(1)
    }
}
