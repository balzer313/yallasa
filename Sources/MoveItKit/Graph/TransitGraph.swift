import Foundation

/// A compiled, queryable transit network.
///
/// This is the single source of truth every other module in the engine agrees
/// on. The importer produces it, the router consumes it, the UI reads names and
/// colours out of it. It is immutable and thread-safe once opened: several
/// concurrent RAPTOR queries can share one instance, because all mutable
/// scratch state lives in the router, never here.
///
/// ## Addressing
///
/// Trips are addressed two ways and it matters which you use:
/// - **Globally**, by `TripIndex`, for attributes (`tripService`, `tripHeadsign`).
/// - **Locally**, by `(pattern, tripOffset)`, for times. Within a pattern, trips
///   are stored contiguously and sorted by departure from the first stop, which
///   is what lets the router binary-search for "the next trip I can catch".
///
/// `globalTripIndex(pattern:offset:)` converts between them.
public final class TransitGraph: @unchecked Sendable {
    public let metadata: GraphMetadata
    private let memory: GraphMemory

    // MARK: Columns

    private let stringBlob: UnsafeBufferPointer<UInt8>

    private let stopLatitudeE6: UnsafeBufferPointer<Int32>
    private let stopLongitudeE6: UnsafeBufferPointer<Int32>
    private let stopNameRef: UnsafeBufferPointer<UInt32>
    private let stopCodeRef: UnsafeBufferPointer<UInt32>
    private let stopIdentifierRef: UnsafeBufferPointer<UInt32>
    private let stopPlatformRef: UnsafeBufferPointer<UInt32>
    private let stopParentColumn: UnsafeBufferPointer<Int32>
    private let stopFlagsColumn: UnsafeBufferPointer<UInt8>
    private let stopPatternStart: UnsafeBufferPointer<UInt32>
    private let stopPatternCountColumn: UnsafeBufferPointer<UInt32>
    private let stopTransferStart: UnsafeBufferPointer<UInt32>
    private let stopTransferCountColumn: UnsafeBufferPointer<UInt32>

    /// CSR payloads: for stop `s`, the patterns serving it are
    /// `stopPatternReferences[stopPatternStart[s] ..< +stopPatternCount[s]]`,
    /// with the stop's position along each pattern at the same index in
    /// `stopPatternPositions`.
    public let stopPatternReferences: UnsafeBufferPointer<Int32>
    public let stopPatternPositions: UnsafeBufferPointer<UInt16>

    public let transferTargets: UnsafeBufferPointer<Int32>
    public let transferSecondsColumn: UnsafeBufferPointer<Int32>
    public let transferMetersColumn: UnsafeBufferPointer<Int32>

    private let patternRouteColumn: UnsafeBufferPointer<Int32>
    private let patternStopStart: UnsafeBufferPointer<UInt32>
    private let patternStopCountColumn: UnsafeBufferPointer<UInt32>
    private let patternTripStart: UnsafeBufferPointer<UInt32>
    private let patternTripCountColumn: UnsafeBufferPointer<UInt32>
    private let patternStopTimeStart: UnsafeBufferPointer<UInt32>
    private let patternHeadsignRef: UnsafeBufferPointer<UInt32>
    private let patternDirectionColumn: UnsafeBufferPointer<UInt8>
    private let patternFlagsColumn: UnsafeBufferPointer<UInt8>
    public let patternStopReferences: UnsafeBufferPointer<Int32>
    private let patternPickupColumn: UnsafeBufferPointer<UInt8>
    private let patternDropOffColumn: UnsafeBufferPointer<UInt8>
    private let patternStopDistanceColumn: UnsafeBufferPointer<Int32>

    private let tripServiceColumn: UnsafeBufferPointer<Int32>
    private let tripIdentifierRef: UnsafeBufferPointer<UInt32>
    private let tripHeadsignRef: UnsafeBufferPointer<UInt32>
    private let tripShortNameRef: UnsafeBufferPointer<UInt32>
    private let tripFlagsColumn: UnsafeBufferPointer<UInt8>

    /// The two hottest columns in the engine. Indexed by
    /// `patternStopTimeStart[p] + tripOffset * patternStopCount[p] + position`.
    public let stopTimeArrivals: UnsafeBufferPointer<Int32>
    public let stopTimeDepartures: UnsafeBufferPointer<Int32>

    private let routeShortNameRef: UnsafeBufferPointer<UInt32>
    private let routeLongNameRef: UnsafeBufferPointer<UInt32>
    private let routeIdentifierRef: UnsafeBufferPointer<UInt32>
    private let routeDescriptionRef: UnsafeBufferPointer<UInt32>
    private let routeTypeColumn: UnsafeBufferPointer<UInt16>
    private let routeColorColumn: UnsafeBufferPointer<UInt32>
    private let routeTextColorColumn: UnsafeBufferPointer<UInt32>
    private let routeAgencyColumn: UnsafeBufferPointer<Int32>

    private let agencyNameRef: UnsafeBufferPointer<UInt32>
    private let agencyIdentifierRef: UnsafeBufferPointer<UInt32>
    private let agencyURLRef: UnsafeBufferPointer<UInt32>
    private let agencyTimeZoneRef: UnsafeBufferPointer<UInt32>

    private let serviceBits: UnsafeBufferPointer<UInt8>
    private let serviceIdentifierRef: UnsafeBufferPointer<UInt32>

    private let gridCellStart: UnsafeBufferPointer<UInt32>
    private let gridCellCountColumn: UnsafeBufferPointer<UInt32>
    private let gridStopReferences: UnsafeBufferPointer<Int32>

    // MARK: - Opening

    public static func open(contentsOf url: URL) throws -> TransitGraph {
        try TransitGraph(memory: GraphMemory.map(contentsOf: url))
    }

    public static func open(data: Data) throws -> TransitGraph {
        try TransitGraph(memory: GraphMemory.copying(data))
    }

    public init(memory: GraphMemory) throws {
        self.memory = memory

        guard memory.count >= GraphFormat.headerReservedBytes else { throw GraphError.fileTooSmall }
        guard try memory.loadUnaligned(byteOffset: 0, as: UInt32.self) == GraphFormat.magic else {
            throw GraphError.badMagic
        }
        let version: UInt32 = try memory.loadUnaligned(byteOffset: 4, as: UInt32.self)
        guard version == GraphFormat.version else { throw GraphError.unsupportedVersion(version) }
        let descriptorCount = Int(try memory.loadUnaligned(byteOffset: 8, as: UInt32.self))
        let maximumDescriptors = (GraphFormat.headerReservedBytes - 16) / GraphSectionDescriptor.encodedSize
        guard descriptorCount <= maximumDescriptors else {
            throw GraphError.malformedSection(.metadata, reason: "section table overflows the header")
        }

        var table: [UInt32: GraphSectionDescriptor] = [:]
        table.reserveCapacity(descriptorCount)
        for index in 0..<descriptorCount {
            let base = 16 + index * GraphSectionDescriptor.encodedSize
            let rawIdentifier: UInt32 = try memory.loadUnaligned(byteOffset: base, as: UInt32.self)
            let elementSize: UInt32 = try memory.loadUnaligned(byteOffset: base + 4, as: UInt32.self)
            let elementCount: UInt64 = try memory.loadUnaligned(byteOffset: base + 8, as: UInt64.self)
            let byteOffset: UInt64 = try memory.loadUnaligned(byteOffset: base + 16, as: UInt64.self)
            guard let section = GraphSection(rawValue: rawIdentifier) else { continue }
            table[rawIdentifier] = GraphSectionDescriptor(
                section: section,
                elementSize: elementSize,
                elementCount: elementCount,
                byteOffset: byteOffset
            )
        }

        // Metadata first: the counts inside it are what every other section is
        // validated against, so a mismatch is caught here rather than in a query.
        guard let metadataDescriptor = table[GraphSection.metadata.rawValue] else {
            throw GraphError.missingSection(.metadata)
        }
        let metadataBytes = try memory.rawBytes(
            byteOffset: Int(metadataDescriptor.byteOffset),
            count: metadataDescriptor.byteCount
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            self.metadata = try decoder.decode(GraphMetadata.self, from: Data(metadataBytes))
        } catch {
            throw GraphError.metadataDecodingFailed(String(describing: error))
        }

        let counts = metadata.counts

        func bind<T>(
            _ section: GraphSection,
            as _: T.Type,
            expecting expectedCount: Int?,
            required: Bool = true
        ) throws -> UnsafeBufferPointer<T> {
            guard let descriptor = table[section.rawValue] else {
                if required, (expectedCount ?? 0) > 0 { throw GraphError.missingSection(section) }
                return UnsafeBufferPointer(start: nil, count: 0)
            }
            guard Int(descriptor.elementSize) == MemoryLayout<T>.stride else {
                throw GraphError.malformedSection(
                    section,
                    reason: "element size \(descriptor.elementSize) != \(MemoryLayout<T>.stride)"
                )
            }
            if let expectedCount, Int(descriptor.elementCount) != expectedCount {
                throw GraphError.malformedSection(
                    section,
                    reason: "has \(descriptor.elementCount) elements, expected \(expectedCount)"
                )
            }
            return try memory.buffer(
                byteOffset: Int(descriptor.byteOffset),
                count: Int(descriptor.elementCount),
                as: T.self,
                section: section
            )
        }

        self.stringBlob = try bind(.stringBlob, as: UInt8.self, expecting: nil)

        let stopCount = counts.stops
        self.stopLatitudeE6 = try bind(.stopLatitudeE6, as: Int32.self, expecting: stopCount)
        self.stopLongitudeE6 = try bind(.stopLongitudeE6, as: Int32.self, expecting: stopCount)
        self.stopNameRef = try bind(.stopName, as: UInt32.self, expecting: stopCount)
        self.stopCodeRef = try bind(.stopCode, as: UInt32.self, expecting: stopCount)
        self.stopIdentifierRef = try bind(.stopIdentifier, as: UInt32.self, expecting: stopCount)
        self.stopPlatformRef = try bind(.stopPlatformCode, as: UInt32.self, expecting: stopCount)
        self.stopParentColumn = try bind(.stopParent, as: Int32.self, expecting: stopCount)
        self.stopFlagsColumn = try bind(.stopFlags, as: UInt8.self, expecting: stopCount)
        self.stopPatternStart = try bind(.stopPatternStart, as: UInt32.self, expecting: stopCount)
        self.stopPatternCountColumn = try bind(.stopPatternCount, as: UInt32.self, expecting: stopCount)
        self.stopTransferStart = try bind(.stopTransferStart, as: UInt32.self, expecting: stopCount)
        self.stopTransferCountColumn = try bind(.stopTransferCount, as: UInt32.self, expecting: stopCount)

        self.stopPatternReferences = try bind(.stopPatternReference, as: Int32.self, expecting: nil)
        self.stopPatternPositions = try bind(
            .stopPatternPosition, as: UInt16.self, expecting: stopPatternReferences.count
        )

        self.transferTargets = try bind(.transferTarget, as: Int32.self, expecting: counts.transfers)
        self.transferSecondsColumn = try bind(.transferSeconds, as: Int32.self, expecting: counts.transfers)
        self.transferMetersColumn = try bind(.transferMeters, as: Int32.self, expecting: counts.transfers)

        let patternCount = counts.patterns
        self.patternRouteColumn = try bind(.patternRoute, as: Int32.self, expecting: patternCount)
        self.patternStopStart = try bind(.patternStopStart, as: UInt32.self, expecting: patternCount)
        self.patternStopCountColumn = try bind(.patternStopCount, as: UInt32.self, expecting: patternCount)
        self.patternTripStart = try bind(.patternTripStart, as: UInt32.self, expecting: patternCount)
        self.patternTripCountColumn = try bind(.patternTripCount, as: UInt32.self, expecting: patternCount)
        self.patternStopTimeStart = try bind(.patternStopTimeStart, as: UInt32.self, expecting: patternCount)
        self.patternHeadsignRef = try bind(.patternHeadsign, as: UInt32.self, expecting: patternCount)
        self.patternDirectionColumn = try bind(.patternDirection, as: UInt8.self, expecting: patternCount)
        self.patternFlagsColumn = try bind(.patternFlags, as: UInt8.self, expecting: patternCount)

        self.patternStopReferences = try bind(.patternStopReference, as: Int32.self, expecting: nil)
        let patternStopSlots = patternStopReferences.count
        self.patternPickupColumn = try bind(.patternPickup, as: UInt8.self, expecting: patternStopSlots)
        self.patternDropOffColumn = try bind(.patternDropOff, as: UInt8.self, expecting: patternStopSlots)
        self.patternStopDistanceColumn = try bind(
            .patternStopDistance, as: Int32.self, expecting: patternStopSlots
        )

        let tripCount = counts.trips
        self.tripServiceColumn = try bind(.tripService, as: Int32.self, expecting: tripCount)
        self.tripIdentifierRef = try bind(.tripIdentifier, as: UInt32.self, expecting: tripCount)
        self.tripHeadsignRef = try bind(.tripHeadsign, as: UInt32.self, expecting: tripCount)
        self.tripShortNameRef = try bind(.tripShortName, as: UInt32.self, expecting: tripCount)
        self.tripFlagsColumn = try bind(.tripFlags, as: UInt8.self, expecting: tripCount)

        self.stopTimeArrivals = try bind(.stopTimeArrival, as: Int32.self, expecting: counts.stopTimes)
        self.stopTimeDepartures = try bind(.stopTimeDeparture, as: Int32.self, expecting: counts.stopTimes)

        let routeCount = counts.routes
        self.routeShortNameRef = try bind(.routeShortName, as: UInt32.self, expecting: routeCount)
        self.routeLongNameRef = try bind(.routeLongName, as: UInt32.self, expecting: routeCount)
        self.routeIdentifierRef = try bind(.routeIdentifier, as: UInt32.self, expecting: routeCount)
        self.routeDescriptionRef = try bind(.routeDescription, as: UInt32.self, expecting: routeCount)
        self.routeTypeColumn = try bind(.routeType, as: UInt16.self, expecting: routeCount)
        self.routeColorColumn = try bind(.routeColor, as: UInt32.self, expecting: routeCount)
        self.routeTextColorColumn = try bind(.routeTextColor, as: UInt32.self, expecting: routeCount)
        self.routeAgencyColumn = try bind(.routeAgency, as: Int32.self, expecting: routeCount)

        let agencyCount = counts.agencies
        self.agencyNameRef = try bind(.agencyName, as: UInt32.self, expecting: agencyCount)
        self.agencyIdentifierRef = try bind(.agencyIdentifier, as: UInt32.self, expecting: agencyCount)
        self.agencyURLRef = try bind(.agencyURL, as: UInt32.self, expecting: agencyCount)
        self.agencyTimeZoneRef = try bind(.agencyTimeZone, as: UInt32.self, expecting: agencyCount)

        self.serviceBits = try bind(
            .serviceBits, as: UInt8.self,
            expecting: counts.services * metadata.serviceBitsetStride
        )
        self.serviceIdentifierRef = try bind(.serviceIdentifier, as: UInt32.self, expecting: counts.services)

        let cellCount = metadata.grid.rows * metadata.grid.columns
        self.gridCellStart = try bind(.gridCellStart, as: UInt32.self, expecting: cellCount)
        self.gridCellCountColumn = try bind(.gridCellCount, as: UInt32.self, expecting: cellCount)
        self.gridStopReferences = try bind(.gridStopReference, as: Int32.self, expecting: nil)
    }

    // MARK: - Sizes

    public var stopCount: Int { stopLatitudeE6.count }
    public var patternCount: Int { patternRouteColumn.count }
    public var tripCount: Int { tripServiceColumn.count }
    public var routeCount: Int { routeTypeColumn.count }
    public var agencyCount: Int { agencyNameRef.count }
    public var serviceCount: Int { serviceIdentifierRef.count }
    public var transferCount: Int { transferTargets.count }

    public var timeZone: TimeZone { metadata.timeZone }

    /// Nudges the kernel to fault in the stop-time columns. Worth calling before
    /// the first query after launch; without it the first plan pays a few
    /// hundred page faults and feels sluggish in a way later plans do not.
    public func warmUp() {
        memory.prefetch(byteOffset: 0, byteCount: min(memory.count, 8 << 20))
    }

    // MARK: - Strings

    /// Materialises the string at a blob offset. Offset `0` is the empty string.
    public func string(at reference: UInt32) -> String {
        let bytes = utf8(at: reference)
        guard bytes.count > 0, let base = bytes.baseAddress else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base, count: bytes.count), as: UTF8.self)
    }

    /// The raw UTF-8 of a blob string, without allocating. Search compares
    /// against this directly; building a `String` per stop would dominate the
    /// cost of typing a character into the search field.
    public func utf8(at reference: UInt32) -> UnsafeBufferPointer<UInt8> {
        let start = Int(reference)
        guard start < stringBlob.count, let base = stringBlob.baseAddress else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        var end = start
        while end < stringBlob.count, stringBlob[end] != 0 { end += 1 }
        guard end > start else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: base + start, count: end - start)
    }

    // MARK: - Stops

    @inlinable
    public func isValid(stop: StopIndex) -> Bool { stop >= 0 && Int(stop) < stopCount }

    public func stopCoordinate(_ stop: StopIndex) -> GeoPoint {
        GeoPoint(latitudeE6: stopLatitudeE6[Int(stop)], longitudeE6: stopLongitudeE6[Int(stop)])
    }

    public func stopName(_ stop: StopIndex) -> String { string(at: stopNameRef[Int(stop)]) }
    public func stopCode(_ stop: StopIndex) -> String { string(at: stopCodeRef[Int(stop)]) }
    public func stopIdentifier(_ stop: StopIndex) -> String { string(at: stopIdentifierRef[Int(stop)]) }
    public func stopPlatformCode(_ stop: StopIndex) -> String { string(at: stopPlatformRef[Int(stop)]) }
    public func stopNameUTF8(_ stop: StopIndex) -> UnsafeBufferPointer<UInt8> { utf8(at: stopNameRef[Int(stop)]) }

    /// The parent station, or `noIndex` for a standalone stop.
    public func stopParent(_ stop: StopIndex) -> StopIndex { stopParentColumn[Int(stop)] }

    /// The stop itself if it has no parent, otherwise its station. Used to group
    /// platforms into one row on a departures board.
    public func stopStation(_ stop: StopIndex) -> StopIndex {
        let parent = stopParentColumn[Int(stop)]
        return parent == noIndex ? stop : parent
    }

    public func stopAccessibility(_ stop: StopIndex) -> AccessibilityFlag {
        AccessibilityFlag(rawValue: stopFlagsColumn[Int(stop)] & 0b11) ?? .unknown
    }

    /// True for `location_type = 1` records, which are stations rather than
    /// boarding points and are never used as a boarding location by the router.
    public func stopIsStation(_ stop: StopIndex) -> Bool {
        stopFlagsColumn[Int(stop)] & 0b100 != 0
    }

    /// Indices into `stopPatternReferences` / `stopPatternPositions`.
    @inlinable
    public func patternSlots(atStop stop: StopIndex) -> Range<Int> {
        let start = Int(stopPatternStart[Int(stop)])
        return start ..< (start + Int(stopPatternCountColumn[Int(stop)]))
    }

    /// Indices into the `transfer*` columns.
    @inlinable
    public func transferSlots(fromStop stop: StopIndex) -> Range<Int> {
        let start = Int(stopTransferStart[Int(stop)])
        return start ..< (start + Int(stopTransferCountColumn[Int(stop)]))
    }

    /// Convenience for UI code, which is not in a hot loop.
    public func patterns(atStop stop: StopIndex) -> [(pattern: PatternIndex, position: Int)] {
        patternSlots(atStop: stop).map {
            (pattern: stopPatternReferences[$0], position: Int(stopPatternPositions[$0]))
        }
    }

    public func transfers(fromStop stop: StopIndex) -> [(target: StopIndex, seconds: Int32, meters: Int32)] {
        transferSlots(fromStop: stop).map {
            (target: transferTargets[$0], seconds: transferSecondsColumn[$0], meters: transferMetersColumn[$0])
        }
    }

    // MARK: - Patterns

    public func patternRoute(_ pattern: PatternIndex) -> RouteIndex { patternRouteColumn[Int(pattern)] }

    @inlinable
    public func patternStopCount(_ pattern: PatternIndex) -> Int { Int(patternStopCountColumn[Int(pattern)]) }

    @inlinable
    public func patternTripCount(_ pattern: PatternIndex) -> Int { Int(patternTripCountColumn[Int(pattern)]) }

    /// Index into `patternStopReferences` of the pattern's first stop.
    @inlinable
    public func patternStopBase(_ pattern: PatternIndex) -> Int { Int(patternStopStart[Int(pattern)]) }

    @inlinable
    public func patternStop(_ pattern: PatternIndex, at position: Int) -> StopIndex {
        patternStopReferences[patternStopBase(pattern) + position]
    }

    public func patternStops(_ pattern: PatternIndex) -> UnsafeBufferPointer<Int32> {
        let base = patternStopBase(pattern)
        guard let start = patternStopReferences.baseAddress else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: start + base, count: patternStopCount(pattern))
    }

    /// Whether the router may board a vehicle of this pattern at `position`.
    /// False at the final stop and wherever the feed says drop-off only.
    @inlinable
    public func patternAllowsBoarding(_ pattern: PatternIndex, at position: Int) -> Bool {
        position < patternStopCount(pattern) - 1
            && patternPickupColumn[patternStopBase(pattern) + position] == StopServiceAvailability.regular.rawValue
    }

    /// Whether the router may alight at `position`. False at the first stop.
    @inlinable
    public func patternAllowsAlighting(_ pattern: PatternIndex, at position: Int) -> Bool {
        position > 0
            && patternDropOffColumn[patternStopBase(pattern) + position] == StopServiceAvailability.regular.rawValue
    }

    public func patternHeadsign(_ pattern: PatternIndex) -> String {
        string(at: patternHeadsignRef[Int(pattern)])
    }

    public func patternDirection(_ pattern: PatternIndex) -> UInt8 {
        patternDirectionColumn[Int(pattern)]
    }

    public func patternAccessibility(_ pattern: PatternIndex) -> AccessibilityFlag {
        AccessibilityFlag(rawValue: patternFlagsColumn[Int(pattern)] & 0b11) ?? .unknown
    }

    /// Metres along the pattern from its first stop to `position`, straight-line
    /// and cumulative. Good enough to place stops proportionally on a line diagram.
    public func patternDistance(_ pattern: PatternIndex, at position: Int) -> Int32 {
        patternStopDistanceColumn[patternStopBase(pattern) + position]
    }

    // MARK: - Trips

    @inlinable
    public func globalTripIndex(_ pattern: PatternIndex, offset: Int) -> TripIndex {
        TripIndex(Int(patternTripStart[Int(pattern)]) + offset)
    }

    /// The global trip range of a pattern, in departure order.
    @inlinable
    public func tripRange(ofPattern pattern: PatternIndex) -> Range<Int> {
        let start = Int(patternTripStart[Int(pattern)])
        return start ..< (start + patternTripCount(pattern))
    }

    @inlinable
    public func tripService(_ trip: TripIndex) -> ServiceIndex { tripServiceColumn[Int(trip)] }

    public func tripIdentifier(_ trip: TripIndex) -> String { string(at: tripIdentifierRef[Int(trip)]) }
    public func tripHeadsign(_ trip: TripIndex) -> String { string(at: tripHeadsignRef[Int(trip)]) }
    public func tripShortName(_ trip: TripIndex) -> String { string(at: tripShortNameRef[Int(trip)]) }

    public func tripAccessibility(_ trip: TripIndex) -> AccessibilityFlag {
        AccessibilityFlag(rawValue: tripFlagsColumn[Int(trip)] & 0b11) ?? .unknown
    }

    public func tripAllowsBicycles(_ trip: TripIndex) -> AccessibilityFlag {
        AccessibilityFlag(rawValue: (tripFlagsColumn[Int(trip)] >> 2) & 0b11) ?? .unknown
    }

    /// Index into `stopTimeArrivals` / `stopTimeDepartures`.
    @inlinable
    public func stopTimeIndex(pattern: PatternIndex, tripOffset: Int, position: Int) -> Int {
        Int(patternStopTimeStart[Int(pattern)]) + tripOffset * patternStopCount(pattern) + position
    }

    @inlinable
    public func arrivalTime(pattern: PatternIndex, tripOffset: Int, position: Int) -> ServiceSeconds {
        stopTimeArrivals[stopTimeIndex(pattern: pattern, tripOffset: tripOffset, position: position)]
    }

    @inlinable
    public func departureTime(pattern: PatternIndex, tripOffset: Int, position: Int) -> ServiceSeconds {
        stopTimeDepartures[stopTimeIndex(pattern: pattern, tripOffset: tripOffset, position: position)]
    }

    // MARK: - Routes and agencies

    public func routeShortName(_ route: RouteIndex) -> String { string(at: routeShortNameRef[Int(route)]) }
    public func routeLongName(_ route: RouteIndex) -> String { string(at: routeLongNameRef[Int(route)]) }
    public func routeIdentifier(_ route: RouteIndex) -> String { string(at: routeIdentifierRef[Int(route)]) }
    public func routeDescription(_ route: RouteIndex) -> String { string(at: routeDescriptionRef[Int(route)]) }

    /// Short name if the feed has one, otherwise long name — what goes in the
    /// line badge.
    public func routeDisplayName(_ route: RouteIndex) -> String {
        let short = routeShortName(route)
        return short.isEmpty ? routeLongName(route) : short
    }

    public func routeMode(_ route: RouteIndex) -> TransitMode {
        TransitMode(gtfsRouteType: Int(routeTypeColumn[Int(route)]))
    }

    public func routeRawType(_ route: RouteIndex) -> Int { Int(routeTypeColumn[Int(route)]) }

    /// `0xRRGGBB`, falling back to the mode's default when the feed omits it.
    public func routeColor(_ route: RouteIndex) -> UInt32 {
        let stored = routeColorColumn[Int(route)]
        return stored == UInt32.max ? routeMode(route).defaultColor : stored
    }

    public func routeTextColor(_ route: RouteIndex) -> UInt32 {
        let stored = routeTextColorColumn[Int(route)]
        if stored != UInt32.max { return stored }
        return TransitGraph.contrastingTextColor(on: routeColor(route))
    }

    /// WCAG relative-luminance pick between black and white. Feeds routinely
    /// give a `route_color` and no `route_text_color`, and guessing white makes
    /// half the line badges in some feeds unreadable.
    public static func contrastingTextColor(on background: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((background >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return luminance > 0.179 ? 0x000000 : 0xFFFFFF
    }

    public func routeAgency(_ route: RouteIndex) -> AgencyIndex { routeAgencyColumn[Int(route)] }

    public func agencyName(_ agency: AgencyIndex) -> String {
        guard agency >= 0, Int(agency) < agencyCount else { return "" }
        return string(at: agencyNameRef[Int(agency)])
    }

    public func agencyIdentifier(_ agency: AgencyIndex) -> String {
        guard agency >= 0, Int(agency) < agencyCount else { return "" }
        return string(at: agencyIdentifierRef[Int(agency)])
    }

    public func agencyURL(_ agency: AgencyIndex) -> String {
        guard agency >= 0, Int(agency) < agencyCount else { return "" }
        return string(at: agencyURLRef[Int(agency)])
    }

    public func agencyTimeZone(_ agency: AgencyIndex) -> String {
        guard agency >= 0, Int(agency) < agencyCount else { return metadata.timeZoneIdentifier }
        let value = string(at: agencyTimeZoneRef[Int(agency)])
        return value.isEmpty ? metadata.timeZoneIdentifier : value
    }

    // MARK: - Calendar

    /// Position of `date` in the graph's bitset range, or nil when the feed does
    /// not cover it.
    @inlinable
    public func dayIndex(for date: ServiceDate) -> Int? {
        let index = date.days(since: metadata.calendarStart)
        guard index >= 0, index < metadata.calendarDayCount else { return nil }
        return index
    }

    @inlinable
    public func isServiceActive(_ service: ServiceIndex, dayIndex: Int) -> Bool {
        guard service >= 0, dayIndex >= 0, dayIndex < metadata.calendarDayCount else { return false }
        let byteIndex = Int(service) * metadata.serviceBitsetStride + (dayIndex >> 3)
        guard byteIndex < serviceBits.count else { return false }
        return serviceBits[byteIndex] & (1 << UInt8(dayIndex & 7)) != 0
    }

    public func serviceIdentifier(_ service: ServiceIndex) -> String {
        guard service >= 0, Int(service) < serviceCount else { return "" }
        return string(at: serviceIdentifierRef[Int(service)])
    }

    /// Whether any service at all runs on `date`. A "no journeys found" that is
    /// really "the feed has no data for today" deserves a different message.
    public func hasAnyService(on date: ServiceDate) -> Bool {
        guard let dayIndex = dayIndex(for: date) else { return false }
        let byteOffset = dayIndex >> 3
        let mask = UInt8(1 << UInt8(dayIndex & 7))
        for service in 0..<serviceCount {
            let index = service * metadata.serviceBitsetStride + byteOffset
            if index < serviceBits.count, serviceBits[index] & mask != 0 { return true }
        }
        return false
    }

    // MARK: - Spatial lookup

    /// Stops within `radiusMeters`, nearest first.
    ///
    /// Scans only the grid cells the circle touches. With ~30 m cells and a
    /// 500 m radius that is a few hundred candidates out of a feed's tens of
    /// thousands of stops, which is what keeps the nearby board instant.
    public func stops(
        near point: GeoPoint,
        radiusMeters: Double,
        limit: Int = .max,
        includeStations: Bool = false
    ) -> [NearbyStop] {
        let grid = metadata.grid
        guard grid.rows > 0, grid.columns > 0, radiusMeters > 0 else { return [] }

        let latitudeSpan = GeoPoint.latitudeDegrees(forMeters: radiusMeters)
        let longitudeSpan = point.longitudeDegrees(forMeters: radiusMeters)

        let minimumRow = max(0, grid.row(forLatitude: point.latitude - latitudeSpan))
        let maximumRow = min(grid.rows - 1, grid.row(forLatitude: point.latitude + latitudeSpan))
        let minimumColumn = max(0, grid.column(forLongitude: point.longitude - longitudeSpan))
        let maximumColumn = min(grid.columns - 1, grid.column(forLongitude: point.longitude + longitudeSpan))
        guard minimumRow <= maximumRow, minimumColumn <= maximumColumn else { return [] }

        var results: [NearbyStop] = []
        results.reserveCapacity(64)

        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                guard let cell = grid.cellIndex(row: row, column: column), cell < gridCellStart.count else { continue }
                let start = Int(gridCellStart[cell])
                let end = start + Int(gridCellCountColumn[cell])
                guard end <= gridStopReferences.count else { continue }
                for slot in start..<end {
                    let stop = gridStopReferences[slot]
                    if !includeStations, stopIsStation(stop) { continue }
                    let distance = point.approximateDistance(to: stopCoordinate(stop))
                    if distance <= radiusMeters {
                        results.append(NearbyStop(stop: stop, distanceMeters: distance))
                    }
                }
            }
        }

        results.sort { $0.distanceMeters < $1.distanceMeters }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }

    /// Nearest stops regardless of radius, by growing the search until enough are
    /// found. Used when a user drops a pin somewhere with sparse coverage.
    public func nearestStops(to point: GeoPoint, limit: Int, maximumRadiusMeters: Double = 5000) -> [NearbyStop] {
        var radius = 400.0
        while radius <= maximumRadiusMeters {
            let found = stops(near: point, radiusMeters: radius, limit: limit)
            if found.count >= limit || radius >= maximumRadiusMeters { return found }
            radius *= 2
        }
        return stops(near: point, radiusMeters: maximumRadiusMeters, limit: limit)
    }
}

/// A stop and how far it is from the query point.
public struct NearbyStop: Hashable, Sendable {
    public let stop: StopIndex
    public let distanceMeters: Double

    public init(stop: StopIndex, distanceMeters: Double) {
        self.stop = stop
        self.distanceMeters = distanceMeters
    }
}
