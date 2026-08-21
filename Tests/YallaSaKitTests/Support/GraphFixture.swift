import Foundation
@testable import YallaSaKit

/// Builds a real transit graph from a hand-written description.
///
/// Deliberately not a mock. It writes the actual binary format through
/// `TransitGraphWriter` and reads it back through `TransitGraph`, so a test that
/// passes here proves the router agrees with the reader's addressing — which is
/// exactly the class of bug (an off-by-one in `patternStopTimeStart`, a CSR range
/// that points at the wrong stop) that a mocked graph would hide.
///
/// Coordinates are in a tight cluster around a fictional city so that the
/// spatial grid has several cells and nearby-stop queries do real work.
struct GraphFixture {

    // MARK: - Specifications

    struct StopSpec {
        var name: String
        var latitude: Double
        var longitude: Double
        var code: String = ""
        var identifier: String = ""
        /// Index into `stops`, for a platform belonging to a station.
        var parent: Int?
        var isStation = false
        var accessibility: AccessibilityFlag = .unknown

        init(
            _ name: String,
            latitude: Double,
            longitude: Double,
            code: String = "",
            identifier: String = "",
            parent: Int? = nil,
            isStation: Bool = false,
            accessibility: AccessibilityFlag = .unknown
        ) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.code = code
            self.identifier = identifier.isEmpty ? name.lowercased().replacingOccurrences(of: " ", with: "_") : identifier
            self.parent = parent
            self.isStation = isStation
            self.accessibility = accessibility
        }
    }

    struct RouteSpec {
        var shortName: String
        var longName: String = ""
        var identifier: String = ""
        var routeType: Int = 3
        var color: UInt32 = .max
        var textColor: UInt32 = .max
        var agency: Int = 0

        init(
            _ shortName: String,
            longName: String = "",
            identifier: String = "",
            routeType: Int = 3,
            color: UInt32 = .max
        ) {
            self.shortName = shortName
            self.longName = longName
            self.identifier = identifier.isEmpty ? "r_" + shortName.lowercased() : identifier
            self.routeType = routeType
            self.color = color
        }
    }

    struct PatternSpec {
        var route: Int
        var stops: [Int]
        var headsign: String = ""
        var direction: UInt8 = 0
        /// Defaults to "boarding and alighting allowed everywhere".
        var pickup: [UInt8]?
        var dropOff: [UInt8]?

        init(
            route: Int,
            stops: [Int],
            headsign: String = "",
            direction: UInt8 = 0,
            pickup: [UInt8]? = nil,
            dropOff: [UInt8]? = nil
        ) {
            self.route = route
            self.stops = stops
            self.headsign = headsign
            self.direction = direction
            self.pickup = pickup
            self.dropOff = dropOff
        }
    }

    struct TripSpec {
        var pattern: Int
        var service: Int
        var identifier: String
        var headsign: String = ""
        /// One `(arrival, departure)` pair per position along the pattern.
        var times: [(arrival: ServiceSeconds, departure: ServiceSeconds)]
        var accessibility: AccessibilityFlag = .unknown

        init(
            pattern: Int,
            service: Int,
            identifier: String,
            times: [(arrival: ServiceSeconds, departure: ServiceSeconds)],
            headsign: String = "",
            accessibility: AccessibilityFlag = .unknown
        ) {
            self.pattern = pattern
            self.service = service
            self.identifier = identifier
            self.times = times
            self.headsign = headsign
            self.accessibility = accessibility
        }

        /// Convenience: a trip that dwells for zero seconds at every stop.
        init(
            pattern: Int,
            service: Int,
            identifier: String,
            passing times: [ServiceSeconds],
            headsign: String = ""
        ) {
            self.init(
                pattern: pattern,
                service: service,
                identifier: identifier,
                times: times.map { (arrival: $0, departure: $0) },
                headsign: headsign
            )
        }
    }

    struct ServiceSpec {
        var identifier: String
        /// Day indices relative to `calendarStart`.
        var activeDays: [Int]

        init(_ identifier: String, activeDays: [Int]) {
            self.identifier = identifier
            self.activeDays = activeDays
        }
    }

    struct TransferSpec {
        var from: Int
        var to: Int
        var seconds: Int32
        var meters: Int32

        init(from: Int, to: Int, seconds: Int32, meters: Int32 = 0) {
            self.from = from
            self.to = to
            self.seconds = seconds
            self.meters = meters == 0 ? Int32(Double(seconds) * 1.33) : meters
        }
    }

    // MARK: - Contents

    var stops: [StopSpec] = []
    var routes: [RouteSpec] = []
    var patterns: [PatternSpec] = []
    var trips: [TripSpec] = []
    var services: [ServiceSpec] = []
    /// Written as given. The router assumes footpaths are transitively closed, so
    /// a fixture that needs a closure must state it — which is itself a useful
    /// property, because a test can then prove what happens without one.
    var transfers: [TransferSpec] = []

    var agencyName = "Test Transit"
    var agencyIdentifier = "TT"
    /// UTC keeps every assertion in the tests free of DST and locale behaviour.
    var timeZoneIdentifier = "UTC"
    var calendarStart = ServiceDate(year: 2026, month: 8, day: 10)
    var calendarDayCount = 14
    var feedIdentifier = "fixture"

    /// Day index used by tests that do not care which day it is.
    static let defaultDayIndex = 2
    var defaultDate: ServiceDate { calendarStart.adding(days: GraphFixture.defaultDayIndex) }

    private static let gridCellSpan = 0.003

    // MARK: - Building

    func build() throws -> TransitGraph {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yallasa-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fixture.mvtg")
        let metadata = try write(to: url)

        // Read the bytes back and open from memory, so the graph does not depend
        // on the temporary file surviving the test.
        let data = try Data(contentsOf: url)
        let graph = try TransitGraph.open(data: data)
        precondition(graph.metadata.counts.stops == metadata.counts.stops)
        return graph
    }

    @discardableResult
    func write(to url: URL) throws -> GraphMetadata {
        var strings = StringTableBuilder()
        let writer = try TransitGraphWriter(url: url)

        // MARK: Stops

        var stopLatitude: [Int32] = []
        var stopLongitude: [Int32] = []
        var stopName: [UInt32] = []
        var stopCode: [UInt32] = []
        var stopIdentifier: [UInt32] = []
        var stopPlatform: [UInt32] = []
        var stopParent: [Int32] = []
        var stopFlags: [UInt8] = []

        var bounds = GeoBounds.empty
        for stop in stops {
            let point = GeoPoint(latitude: stop.latitude, longitude: stop.longitude)
            bounds.extend(to: point)
            stopLatitude.append(point.latitudeE6)
            stopLongitude.append(point.longitudeE6)
            stopName.append(strings.intern(stop.name))
            stopCode.append(strings.intern(stop.code))
            stopIdentifier.append(strings.intern(stop.identifier))
            stopPlatform.append(0)
            stopParent.append(stop.parent.map { Int32($0) } ?? noIndex)
            // Bits 0-1 accessibility, bit 2 is-station — matching `TransitGraph`.
            var flags = stop.accessibility.rawValue & 0b11
            if stop.isStation { flags |= 0b100 }
            stopFlags.append(flags)
        }

        // MARK: Patterns and trips
        //
        // Trips are grouped by pattern and sorted by departure at position 0,
        // which is the ordering the router's binary search depends on.

        var tripsByPattern: [[TripSpec]] = Array(repeating: [], count: patterns.count)
        for trip in trips {
            precondition(trip.pattern < patterns.count, "trip references pattern \(trip.pattern)")
            precondition(
                trip.times.count == patterns[trip.pattern].stops.count,
                "trip \(trip.identifier) has \(trip.times.count) times for a \(patterns[trip.pattern].stops.count)-stop pattern"
            )
            tripsByPattern[trip.pattern].append(trip)
        }
        for index in tripsByPattern.indices {
            tripsByPattern[index].sort {
                ($0.times.first?.departure ?? 0) < ($1.times.first?.departure ?? 0)
            }
        }

        var patternRoute: [Int32] = []
        var patternStopStart: [UInt32] = []
        var patternStopCount: [UInt32] = []
        var patternTripStart: [UInt32] = []
        var patternTripCount: [UInt32] = []
        var patternStopTimeStart: [UInt32] = []
        var patternHeadsign: [UInt32] = []
        var patternDirection: [UInt8] = []
        var patternFlags: [UInt8] = []

        var patternStopReference: [Int32] = []
        var patternPickup: [UInt8] = []
        var patternDropOff: [UInt8] = []
        var patternStopDistance: [Int32] = []

        var tripService: [Int32] = []
        var tripIdentifier: [UInt32] = []
        var tripHeadsign: [UInt32] = []
        var tripShortName: [UInt32] = []
        var tripFlags: [UInt8] = []

        var stopTimeArrival: [Int32] = []
        var stopTimeDeparture: [Int32] = []

        for (index, pattern) in patterns.enumerated() {
            patternRoute.append(Int32(pattern.route))
            patternStopStart.append(UInt32(patternStopReference.count))
            patternStopCount.append(UInt32(pattern.stops.count))
            patternTripStart.append(UInt32(tripService.count))
            patternTripCount.append(UInt32(tripsByPattern[index].count))
            patternStopTimeStart.append(UInt32(stopTimeArrival.count))
            patternHeadsign.append(strings.intern(pattern.headsign))
            patternDirection.append(pattern.direction)
            patternFlags.append(0)

            var cumulative = 0.0
            for (position, stop) in pattern.stops.enumerated() {
                patternStopReference.append(Int32(stop))
                patternPickup.append(pattern.pickup?[position] ?? 0)
                patternDropOff.append(pattern.dropOff?[position] ?? 0)
                if position > 0 {
                    let previous = pattern.stops[position - 1]
                    cumulative += GeoPoint(
                        latitude: stops[previous].latitude, longitude: stops[previous].longitude
                    ).approximateDistance(
                        to: GeoPoint(latitude: stops[stop].latitude, longitude: stops[stop].longitude)
                    )
                }
                patternStopDistance.append(Int32(cumulative.rounded()))
            }

            for trip in tripsByPattern[index] {
                tripService.append(Int32(trip.service))
                tripIdentifier.append(strings.intern(trip.identifier))
                tripHeadsign.append(strings.intern(trip.headsign))
                tripShortName.append(0)
                tripFlags.append(trip.accessibility.rawValue & 0b11)
                for time in trip.times {
                    stopTimeArrival.append(time.arrival)
                    stopTimeDeparture.append(time.departure)
                }
            }
        }

        // MARK: Stop -> pattern CSR

        var pairsByStop: [[(pattern: Int32, position: UInt16)]] =
            Array(repeating: [], count: stops.count)
        for (index, pattern) in patterns.enumerated() {
            for (position, stop) in pattern.stops.enumerated() {
                pairsByStop[stop].append((pattern: Int32(index), position: UInt16(position)))
            }
        }

        var stopPatternStart: [UInt32] = []
        var stopPatternCount: [UInt32] = []
        var stopPatternReference: [Int32] = []
        var stopPatternPosition: [UInt16] = []
        for pairs in pairsByStop {
            stopPatternStart.append(UInt32(stopPatternReference.count))
            stopPatternCount.append(UInt32(pairs.count))
            for pair in pairs {
                stopPatternReference.append(pair.pattern)
                stopPatternPosition.append(pair.position)
            }
        }

        // MARK: Transfer CSR

        var transfersByStop: [[TransferSpec]] = Array(repeating: [], count: stops.count)
        for transfer in transfers {
            precondition(transfer.from != transfer.to, "a self-transfer is never valid")
            transfersByStop[transfer.from].append(transfer)
        }

        var stopTransferStart: [UInt32] = []
        var stopTransferCount: [UInt32] = []
        var transferTarget: [Int32] = []
        var transferSeconds: [Int32] = []
        var transferMeters: [Int32] = []
        for list in transfersByStop {
            stopTransferStart.append(UInt32(transferTarget.count))
            stopTransferCount.append(UInt32(list.count))
            for transfer in list {
                transferTarget.append(Int32(transfer.to))
                transferSeconds.append(transfer.seconds)
                transferMeters.append(transfer.meters)
            }
        }

        // MARK: Routes and agencies

        var routeShortName: [UInt32] = []
        var routeLongName: [UInt32] = []
        var routeIdentifier: [UInt32] = []
        var routeDescription: [UInt32] = []
        var routeType: [UInt16] = []
        var routeColor: [UInt32] = []
        var routeTextColor: [UInt32] = []
        var routeAgency: [Int32] = []
        for route in routes {
            routeShortName.append(strings.intern(route.shortName))
            routeLongName.append(strings.intern(route.longName))
            routeIdentifier.append(strings.intern(route.identifier))
            routeDescription.append(0)
            routeType.append(UInt16(route.routeType))
            routeColor.append(route.color)
            routeTextColor.append(route.textColor)
            routeAgency.append(Int32(route.agency))
        }

        let agencyNameRef = [strings.intern(agencyName)]
        let agencyIdentifierRef = [strings.intern(agencyIdentifier)]
        let agencyURLRef = [strings.intern("https://example.test")]
        let agencyTimeZoneRef = [strings.intern(timeZoneIdentifier)]

        // MARK: Calendar

        let stride = (calendarDayCount + 7) / 8
        var serviceBits = [UInt8](repeating: 0, count: services.count * stride)
        var serviceIdentifier: [UInt32] = []
        for (index, service) in services.enumerated() {
            serviceIdentifier.append(strings.intern(service.identifier))
            for day in service.activeDays {
                precondition(day >= 0 && day < calendarDayCount, "service day \(day) is outside the calendar")
                serviceBits[index * stride + (day >> 3)] |= UInt8(1 << UInt8(day & 7))
            }
        }

        // MARK: Spatial grid

        var grid = GraphMetadata.Grid.empty
        var gridCellStart: [UInt32] = []
        var gridCellCount: [UInt32] = []
        var gridStopReference: [Int32] = []

        if !stops.isEmpty, !bounds.isEmpty {
            let span = GraphFixture.gridCellSpan
            let columns = max(1, Int(((bounds.maxLongitude - bounds.minLongitude) / span).rounded(.down)) + 1)
            let rows = max(1, Int(((bounds.maxLatitude - bounds.minLatitude) / span).rounded(.down)) + 1)
            grid = GraphMetadata.Grid(
                originLatitude: bounds.minLatitude,
                originLongitude: bounds.minLongitude,
                cellLatitudeSpan: span,
                cellLongitudeSpan: span,
                columns: columns,
                rows: rows
            )

            var cells: [[Int32]] = Array(repeating: [], count: rows * columns)
            for (index, stop) in stops.enumerated() {
                let row = min(max(grid.row(forLatitude: stop.latitude), 0), rows - 1)
                let column = min(max(grid.column(forLongitude: stop.longitude), 0), columns - 1)
                cells[row * columns + column].append(Int32(index))
            }
            for cell in cells {
                gridCellStart.append(UInt32(gridStopReference.count))
                gridCellCount.append(UInt32(cell.count))
                gridStopReference.append(contentsOf: cell)
            }
        }

        // MARK: Metadata

        var metadata = GraphMetadata()
        metadata.feedIdentifier = feedIdentifier
        metadata.feedName = "Fixture"
        metadata.feedVersion = "1"
        metadata.builtAt = Date(timeIntervalSince1970: 1_776_000_000)
        metadata.timeZoneIdentifier = timeZoneIdentifier
        metadata.calendarStart = calendarStart
        metadata.calendarDayCount = calendarDayCount
        metadata.serviceBitsetStride = stride
        metadata.bounds = bounds
        metadata.grid = grid
        metadata.counts.stops = stops.count
        metadata.counts.patterns = patterns.count
        metadata.counts.trips = tripService.count
        metadata.counts.stopTimes = stopTimeArrival.count
        metadata.counts.routes = routes.count
        metadata.counts.agencies = agencyNameRef.count
        metadata.counts.services = services.count
        metadata.counts.transfers = transferTarget.count

        // MARK: Write

        try writer.append(.stopLatitudeE6, stopLatitude)
        try writer.append(.stopLongitudeE6, stopLongitude)
        try writer.append(.stopName, stopName)
        try writer.append(.stopCode, stopCode)
        try writer.append(.stopIdentifier, stopIdentifier)
        try writer.append(.stopPlatformCode, stopPlatform)
        try writer.append(.stopParent, stopParent)
        try writer.append(.stopFlags, stopFlags)
        try writer.append(.stopPatternStart, stopPatternStart)
        try writer.append(.stopPatternCount, stopPatternCount)
        try writer.append(.stopPatternReference, stopPatternReference)
        try writer.append(.stopPatternPosition, stopPatternPosition)
        try writer.append(.stopTransferStart, stopTransferStart)
        try writer.append(.stopTransferCount, stopTransferCount)

        try writer.append(.transferTarget, transferTarget)
        try writer.append(.transferSeconds, transferSeconds)
        try writer.append(.transferMeters, transferMeters)

        try writer.append(.patternRoute, patternRoute)
        try writer.append(.patternStopStart, patternStopStart)
        try writer.append(.patternStopCount, patternStopCount)
        try writer.append(.patternTripStart, patternTripStart)
        try writer.append(.patternTripCount, patternTripCount)
        try writer.append(.patternStopTimeStart, patternStopTimeStart)
        try writer.append(.patternHeadsign, patternHeadsign)
        try writer.append(.patternDirection, patternDirection)
        try writer.append(.patternFlags, patternFlags)
        try writer.append(.patternStopReference, patternStopReference)
        try writer.append(.patternPickup, patternPickup)
        try writer.append(.patternDropOff, patternDropOff)
        try writer.append(.patternStopDistance, patternStopDistance)

        try writer.append(.tripService, tripService)
        try writer.append(.tripIdentifier, tripIdentifier)
        try writer.append(.tripHeadsign, tripHeadsign)
        try writer.append(.tripShortName, tripShortName)
        try writer.append(.tripFlags, tripFlags)

        try writer.append(.stopTimeArrival, stopTimeArrival)
        try writer.append(.stopTimeDeparture, stopTimeDeparture)

        try writer.append(.routeShortName, routeShortName)
        try writer.append(.routeLongName, routeLongName)
        try writer.append(.routeIdentifier, routeIdentifier)
        try writer.append(.routeDescription, routeDescription)
        try writer.append(.routeType, routeType)
        try writer.append(.routeColor, routeColor)
        try writer.append(.routeTextColor, routeTextColor)
        try writer.append(.routeAgency, routeAgency)

        try writer.append(.agencyName, agencyNameRef)
        try writer.append(.agencyIdentifier, agencyIdentifierRef)
        try writer.append(.agencyURL, agencyURLRef)
        try writer.append(.agencyTimeZone, agencyTimeZoneRef)

        try writer.append(.serviceBits, serviceBits)
        try writer.append(.serviceIdentifier, serviceIdentifier)

        try writer.append(.gridCellStart, gridCellStart)
        try writer.append(.gridCellCount, gridCellCount)
        try writer.append(.gridStopReference, gridStopReference)

        // The string blob must be written after everything that interns into it.
        try writer.appendBytes(.stringBlob, strings.finish())

        try writer.finish(metadata: metadata)
        return metadata
    }
}

// MARK: - Ready-made networks

extension GraphFixture {

    /// A deliberately small but non-trivial network.
    ///
    /// ```
    ///   A ──(route 1)── B ──(route 1)── C          A=0 B=1 C=2 D=3 E=4
    ///                   │
    ///              footpath 120s
    ///                   │
    ///                   D ──(route 2)── E
    /// ```
    ///
    /// Route 1 runs A→B→C every 10 minutes from 08:00. Route 2 runs D→E every 10
    /// minutes from 08:20. A rider going A→E must ride 1, walk B→D, then ride 2.
    ///
    /// Service 0 runs every day of the calendar; service 1 runs only on day 5, so
    /// tests can prove a trip is skipped when its service is inactive.
    static func twoLineNetwork() -> GraphFixture {
        var fixture = GraphFixture()

        fixture.stops = [
            StopSpec("Ashfield", latitude: 32.0700, longitude: 34.7700, code: "A1"),
            StopSpec("Bridgeway", latitude: 32.0760, longitude: 34.7760, code: "B1"),
            StopSpec("Carlton", latitude: 32.0820, longitude: 34.7820, code: "C1"),
            StopSpec("Bridgeway East", latitude: 32.0762, longitude: 34.7772, code: "D1"),
            StopSpec("Eastgate", latitude: 32.0900, longitude: 34.7900, code: "E1"),
        ]

        fixture.routes = [
            RouteSpec("1", longName: "Ashfield – Carlton"),
            RouteSpec("2", longName: "Bridgeway East – Eastgate"),
        ]

        fixture.patterns = [
            PatternSpec(route: 0, stops: [0, 1, 2], headsign: "Carlton"),
            PatternSpec(route: 1, stops: [3, 4], headsign: "Eastgate"),
        ]

        fixture.services = [
            ServiceSpec("daily", activeDays: Array(0..<14)),
            ServiceSpec("day5only", activeDays: [5]),
        ]

        // Route 1: 08:00, 08:10, 08:20 from Ashfield. Six minutes A→B, six B→C.
        var route1: [TripSpec] = []
        for (index, start) in [28_800, 29_400, 30_000].enumerated() {
            route1.append(
                TripSpec(
                    pattern: 0,
                    service: 0,
                    identifier: "r1_t\(index)",
                    passing: [ServiceSeconds(start), ServiceSeconds(start + 360), ServiceSeconds(start + 720)],
                    headsign: "Carlton"
                )
            )
        }

        // Route 2: 08:20, 08:30, 08:40 from Bridgeway East. Eight minutes D→E.
        var route2: [TripSpec] = []
        for (index, start) in [30_000, 30_600, 31_200].enumerated() {
            route2.append(
                TripSpec(
                    pattern: 1,
                    service: 0,
                    identifier: "r2_t\(index)",
                    passing: [ServiceSeconds(start), ServiceSeconds(start + 480)],
                    headsign: "Eastgate"
                )
            )
        }

        fixture.trips = route1 + route2

        // Bridgeway and Bridgeway East are a two-minute walk apart, both ways.
        fixture.transfers = [
            TransferSpec(from: 1, to: 3, seconds: 120, meters: 110),
            TransferSpec(from: 3, to: 1, seconds: 120, meters: 110),
        ]

        return fixture
    }

    /// A single line whose last trip departs after midnight, expressed the way
    /// GTFS requires: as the previous service day at 25:10.
    ///
    /// ```
    ///   A ──(night bus)── B          A=0 B=1
    /// ```
    static func afterMidnightNetwork() -> GraphFixture {
        var fixture = GraphFixture()
        fixture.stops = [
            StopSpec("Nightstart", latitude: 32.0700, longitude: 34.7700),
            StopSpec("Nightend", latitude: 32.0760, longitude: 34.7760),
        ]
        fixture.routes = [RouteSpec("N1", longName: "Night line")]
        fixture.patterns = [PatternSpec(route: 0, stops: [0, 1], headsign: "Nightend")]
        fixture.services = [ServiceSpec("daily", activeDays: Array(0..<14))]
        fixture.trips = [
            // 23:40 → 23:55 on the nominal day.
            TripSpec(pattern: 0, service: 0, identifier: "n_evening", passing: [85_200, 86_100]),
            // 25:10 → 25:25, i.e. 01:10 the following morning, still this
            // service day. This is the trip a query at 00:30 must find.
            TripSpec(pattern: 0, service: 0, identifier: "n_late", passing: [90_600, 91_500]),
        ]
        return fixture
    }
}
