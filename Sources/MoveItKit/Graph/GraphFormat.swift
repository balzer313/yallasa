import Foundation

/// On-disk layout of a compiled transit graph (`.mvtg`).
///
/// The file is a header followed by 16-byte-aligned, tightly packed columns —
/// one column per attribute, structure-of-arrays throughout. Two properties
/// drive that choice:
///
/// 1. **It memory-maps.** The router touches arrival/departure times and almost
///    nothing else; with SoA the OS only faults in the pages it needs, and a
///    250 MB graph costs a few MB of resident memory during a query.
/// 2. **It scans fast.** RAPTOR's inner loop walks consecutive `Int32`s. In AoS
///    layout each step would straddle a cache line of fields it never reads.
///
/// The format is little-endian only; every Apple platform we target is LE, and
/// the file is rebuilt from source data on the device that reads it, so no
/// cross-endian compatibility is required.
public enum GraphFormat {
    /// ASCII "MVTG", little-endian.
    public static let magic: UInt32 = 0x4754_564D
    /// Bumped on any layout change. `TransitGraph.open` refuses mismatches, and
    /// the feed manager responds by recompiling from the cached GTFS zip.
    public static let version: UInt32 = 1
    /// Bytes reserved at the head of the file for the section table, so the body
    /// can be streamed out in one pass and the table patched in afterwards.
    public static let headerReservedBytes = 8192
    /// Every section starts on this boundary so typed loads are aligned.
    public static let sectionAlignment = 16
}

/// Identifies one column in the file. Raw values are frozen: adding a section is
/// backwards compatible, renumbering one is not.
public enum GraphSection: UInt32, CaseIterable, Sendable {
    // Strings — a single UTF-8 blob of NUL-terminated values. Offset 0 is always
    // the empty string, so `0` doubles as "no value".
    case stringBlob = 1

    // Stops
    case stopLatitudeE6 = 10
    case stopLongitudeE6 = 11
    case stopName = 12
    case stopCode = 13
    case stopIdentifier = 14
    case stopParent = 15
    case stopFlags = 16
    case stopPlatformCode = 17
    /// CSR index into `stopPatternReference` / `stopPatternPosition`.
    case stopPatternStart = 18
    case stopPatternCount = 19
    case stopPatternReference = 20
    case stopPatternPosition = 21
    /// CSR index into the transfer columns.
    case stopTransferStart = 22
    case stopTransferCount = 23

    // Footpath transfers
    case transferTarget = 30
    case transferSeconds = 31
    case transferMeters = 32

    // Patterns — a pattern is a maximal set of trips sharing an identical
    // ordered stop sequence, which is RAPTOR's notion of a "route".
    case patternRoute = 40
    case patternStopStart = 41
    case patternStopCount = 42
    case patternTripStart = 43
    case patternTripCount = 44
    case patternStopTimeStart = 45
    case patternHeadsign = 46
    case patternDirection = 47
    case patternFlags = 48
    case patternStopReference = 49
    case patternPickup = 50
    case patternDropOff = 51
    /// Cumulative straight-line metres from the pattern's first stop, for
    /// drawing a schematic line diagram without carrying shapes.
    case patternStopDistance = 52

    // Trips, grouped by pattern and sorted by departure at the first stop.
    case tripService = 60
    case tripIdentifier = 61
    case tripHeadsign = 62
    case tripShortName = 63
    case tripFlags = 64

    // Stop times, grouped by pattern then trip then position.
    case stopTimeArrival = 70
    case stopTimeDeparture = 71

    // Routes (lines)
    case routeShortName = 80
    case routeLongName = 81
    case routeIdentifier = 82
    case routeType = 83
    case routeColor = 84
    case routeTextColor = 85
    case routeAgency = 86
    case routeDescription = 87

    // Agencies
    case agencyName = 90
    case agencyIdentifier = 91
    case agencyURL = 92
    case agencyTimeZone = 93

    // Calendar — one fixed-stride bitset per service over the graph's day range.
    case serviceBits = 100
    case serviceIdentifier = 101

    // Uniform spatial grid over the feed bounds, CSR-encoded.
    case gridCellStart = 110
    case gridCellCount = 111
    case gridStopReference = 112

    // Metadata — UTF-8 JSON of `GraphMetadata`.
    case metadata = 120
}

/// One row of the section table.
public struct GraphSectionDescriptor: Sendable {
    public var section: GraphSection
    public var elementSize: UInt32
    public var elementCount: UInt64
    public var byteOffset: UInt64

    public var byteCount: Int { Int(elementCount) * Int(elementSize) }

    public init(section: GraphSection, elementSize: UInt32, elementCount: UInt64, byteOffset: UInt64) {
        self.section = section
        self.elementSize = elementSize
        self.elementCount = elementCount
        self.byteOffset = byteOffset
    }

    /// Serialised width of a descriptor in the header.
    public static let encodedSize = 24
}

/// Everything about a compiled graph that is cheap to read and useful before
/// touching the columns: what feed it came from, how big it is, and the
/// parameters the compiler used. Stored as JSON so it stays readable and
/// forwards-compatible.
public struct GraphMetadata: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable {
        public var stops: Int = 0
        public var patterns: Int = 0
        public var trips: Int = 0
        public var stopTimes: Int = 0
        public var routes: Int = 0
        public var agencies: Int = 0
        public var services: Int = 0
        public var transfers: Int = 0
        public init() {}
    }

    /// Uniform lat/lon grid used for nearby-stop lookups. Cells are square-ish in
    /// metres at the feed's centre latitude, which is all the accuracy a
    /// bounded-radius scan needs.
    public struct Grid: Codable, Sendable, Equatable {
        public var originLatitude: Double
        public var originLongitude: Double
        public var cellLatitudeSpan: Double
        public var cellLongitudeSpan: Double
        public var columns: Int
        public var rows: Int

        public init(
            originLatitude: Double, originLongitude: Double,
            cellLatitudeSpan: Double, cellLongitudeSpan: Double,
            columns: Int, rows: Int
        ) {
            self.originLatitude = originLatitude
            self.originLongitude = originLongitude
            self.cellLatitudeSpan = cellLatitudeSpan
            self.cellLongitudeSpan = cellLongitudeSpan
            self.columns = columns
            self.rows = rows
        }

        public static let empty = Grid(
            originLatitude: 0, originLongitude: 0,
            cellLatitudeSpan: 1, cellLongitudeSpan: 1, columns: 0, rows: 0
        )

        public func column(forLongitude longitude: Double) -> Int {
            Int(((longitude - originLongitude) / cellLongitudeSpan).rounded(.down))
        }

        public func row(forLatitude latitude: Double) -> Int {
            Int(((latitude - originLatitude) / cellLatitudeSpan).rounded(.down))
        }

        public func cellIndex(row: Int, column: Int) -> Int? {
            guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
            return row * columns + column
        }
    }

    /// Compiler inputs worth surfacing, because they change results: a graph
    /// built with a 400 m transfer radius will plan differently from one built
    /// with 800 m, and the UI should be able to say so.
    public struct BuildOptions: Codable, Sendable, Equatable {
        public var maxTransferMeters: Double = 750
        public var maxTransferSeconds: Int = 900
        public var walkingSpeedMetersPerSecond: Double = 1.33
        public var walkingDetourFactor: Double = 1.35
        public var minimumTransferSeconds: Int = 60
        public init() {}
    }

    /// What the importer discarded, and why. Surfaced in Settings so a feed that
    /// silently loses half its trips is visible rather than mysterious.
    public struct ImportReport: Codable, Sendable, Equatable {
        public var droppedStopsMissingCoordinate: Int = 0
        public var droppedStopTimesUnparsableTime: Int = 0
        public var droppedStopTimesUnknownStop: Int = 0
        public var droppedTripsUnknownRoute: Int = 0
        public var droppedTripsUnknownService: Int = 0
        public var droppedTripsTooShort: Int = 0
        public var droppedTransfersUnknownStop: Int = 0
        public var interpolatedStopTimes: Int = 0
        public var warnings: [String] = []
        public init() {}

        public var totalDropped: Int {
            droppedStopsMissingCoordinate + droppedStopTimesUnparsableTime
                + droppedStopTimesUnknownStop + droppedTripsUnknownRoute
                + droppedTripsUnknownService + droppedTripsTooShort
                + droppedTransfersUnknownStop
        }
    }

    public var formatVersion: UInt32 = GraphFormat.version
    public var feedIdentifier: String = ""
    public var feedName: String = ""
    /// From `feed_info.txt` when present, otherwise a hash of the source archive.
    public var feedVersion: String = ""
    public var sourceURL: String = ""
    public var builtAt: Date = .init(timeIntervalSince1970: 0)
    /// IANA identifier from `agency.txt`. Every service time in the graph is
    /// relative to midnight in this zone.
    public var timeZoneIdentifier: String = "UTC"

    /// First day covered by the service bitsets.
    public var calendarStart: ServiceDate = .init(year: 1970, month: 1, day: 1)
    public var calendarDayCount: Int = 0
    /// Bytes per service in `serviceBits`; `ceil(calendarDayCount / 8)`.
    public var serviceBitsetStride: Int = 0

    public var counts = Counts()
    public var bounds = GeoBounds.empty
    public var grid = Grid.empty
    public var buildOptions = BuildOptions()
    public var report = ImportReport()

    public init() {}

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Last day covered, inclusive. Nil when the graph has no calendar at all.
    public var calendarEnd: ServiceDate? {
        guard calendarDayCount > 0 else { return nil }
        return calendarStart.adding(days: calendarDayCount - 1)
    }

    /// Whether the graph can answer questions about `date` at all. A feed that
    /// expired last week is worse than useless — it will confidently return no
    /// journeys — so the UI checks this and prompts for a refresh.
    public func covers(_ date: ServiceDate) -> Bool {
        guard calendarDayCount > 0 else { return false }
        let index = date.days(since: calendarStart)
        return index >= 0 && index < calendarDayCount
    }
}

public enum GraphError: Error, LocalizedError, Equatable {
    case fileTooSmall
    case badMagic
    case unsupportedVersion(UInt32)
    case missingSection(GraphSection)
    case malformedSection(GraphSection, reason: String)
    case sectionOutOfBounds(GraphSection)
    case unalignedSection(GraphSection)
    case metadataDecodingFailed(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooSmall:
            return "The transit graph file is truncated."
        case .badMagic:
            return "This file is not a transit graph."
        case .unsupportedVersion(let version):
            return "Transit graph format version \(version) is not supported; a rebuild is required."
        case .missingSection(let section):
            return "The transit graph is missing its \(section) data."
        case .malformedSection(let section, let reason):
            return "The \(section) data is malformed: \(reason)."
        case .sectionOutOfBounds(let section):
            return "The \(section) data extends past the end of the file."
        case .unalignedSection(let section):
            return "The \(section) data is misaligned."
        case .metadataDecodingFailed(let reason):
            return "The transit graph metadata could not be read: \(reason)."
        case .ioFailure(let reason):
            return reason
        }
    }
}
