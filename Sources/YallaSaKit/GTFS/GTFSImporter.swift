import Foundation

/// Compiles a GTFS archive into a `.mvtg` graph.
///
/// The pipeline is a single forward pass: read the small tables into interned
/// integer columns, stream `stop_times.txt` into flat arrays, group trips into
/// patterns, close the footpath graph, then write the columns straight out. The
/// only structure held twice is the stop-time data, which is why the peak cost of
/// importing a two-million-row feed is tens of megabytes rather than hundreds.
///
/// Nothing here trusts the feed. Every malformed row drops itself and increments a
/// counter in `GraphMetadata.ImportReport`; the import only fails outright when
/// there is nothing left to route on.
public final class GTFSImporter {

    private let options: GTFSImportOptions

    public var onProgress: (@Sendable (GTFSImportProgress) -> Void)?

    /// Return true to abort; checked at least once a second.
    public var isCancelled: (@Sendable () -> Bool)?

    private var strings = StringTableBuilder()
    private var report = GraphMetadata.ImportReport()

    public init(options: GTFSImportOptions) {
        self.options = options
    }

    /// Compiles a GTFS archive into a graph file. On success the file at
    /// `destination` is a complete, openable graph. On any throw, `destination`
    /// is removed.
    public func compile(archiveAt archive: URL, to destination: URL) throws -> GraphMetadata {
        do {
            return try build(archiveAt: archive, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Pipeline

    private func build(archiveAt archiveURL: URL, to destination: URL) throws -> GraphMetadata {
        strings = StringTableBuilder()
        report = GraphMetadata.ImportReport()

        // MARK: Archive

        emit(.openingArchive, 0, "Opening archive")
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: archiveURL)
        } catch {
            throw GTFSImportError.archive(error.localizedDescription)
        }

        for required in ["stops.txt", "routes.txt", "trips.txt", "stop_times.txt"]
        where archive.entry(named: required) == nil {
            throw GTFSImportError.missingRequiredFile(required)
        }
        if archive.entry(named: "calendar.txt") == nil, archive.entry(named: "calendar_dates.txt") == nil {
            throw GTFSImportError.missingRequiredFile("calendar.txt")
        }
        emit(.openingArchive, 1, "Archive opened")
        try checkCancellation()

        // MARK: Agencies

        emit(.agencies, 0, "Reading agencies")
        let agencies = try readTable("agency.txt", in: archive, required: false, { reader in
            GTFSTables.readAgencies(&reader, strings: &self.strings)
        }) ?? GTFSAgencyTable()

        var timeZoneIdentifier = agencies.timeZoneIdentifier
        if timeZoneIdentifier.isEmpty || TimeZone(identifier: timeZoneIdentifier) == nil {
            if !timeZoneIdentifier.isEmpty {
                report.warnings.append("Unknown agency timezone '\(timeZoneIdentifier)'; using UTC.")
            }
            timeZoneIdentifier = "UTC"
        }
        emit(.agencies, 1, "\(agencies.count) agencies")
        try checkCancellation()

        // MARK: Stops

        emit(.stops, 0, "Reading stops")
        let rawStops = try readTable("stops.txt", in: archive, required: true, { reader in
            GTFSTables.readStops(
                &reader,
                strings: &self.strings,
                report: &self.report,
                boundingBox: self.options.boundingBox
            )
        }) ?? GTFSStopTable()
        let stopCount = rawStops.count
        guard stopCount > 0 else { throw GTFSImportError.noUsableStops }

        var bounds = GeoBounds.empty
        for index in 0..<stopCount {
            bounds.extend(to: GeoPoint(latitude: rawStops.latitudes[index], longitude: rawStops.longitudes[index]))
        }
        let grid = GTFSImporter.makeGrid(bounds: bounds)

        // Stops are emitted in grid-cell order so that a nearby-stop scan walks
        // consecutive memory instead of chasing the feed's arbitrary file order.
        var rawCell = [Int32](repeating: 0, count: stopCount)
        for index in 0..<stopCount {
            rawCell[index] = Int32(
                GTFSImporter.cellIndex(grid, latitude: rawStops.latitudes[index], longitude: rawStops.longitudes[index])
            )
        }
        var emitOrder = Array(0..<stopCount)
        emitOrder.sort { left, right in
            rawCell[left] != rawCell[right] ? rawCell[left] < rawCell[right] : left < right
        }

        var stopLatitudeE6 = [Int32](repeating: 0, count: stopCount)
        var stopLongitudeE6 = [Int32](repeating: 0, count: stopCount)
        var stopLatitude = [Double](repeating: 0, count: stopCount)
        var stopLongitude = [Double](repeating: 0, count: stopCount)
        var stopNameRef = [UInt32](repeating: 0, count: stopCount)
        var stopCodeRef = [UInt32](repeating: 0, count: stopCount)
        var stopIdentifierRef = [UInt32](repeating: 0, count: stopCount)
        var stopPlatformRef = [UInt32](repeating: 0, count: stopCount)
        var stopFlags = [UInt8](repeating: 0, count: stopCount)
        var stopParentRef = [UInt32](repeating: 0, count: stopCount)
        var stopCell = [Int32](repeating: 0, count: stopCount)
        var newIndexOfRaw = [Int32](repeating: noIndex, count: stopCount)

        for (newIndex, raw) in emitOrder.enumerated() {
            newIndexOfRaw[raw] = Int32(newIndex)
            stopLatitude[newIndex] = rawStops.latitudes[raw]
            stopLongitude[newIndex] = rawStops.longitudes[raw]
            stopLatitudeE6[newIndex] = GeoPoint.toE6(rawStops.latitudes[raw])
            stopLongitudeE6[newIndex] = GeoPoint.toE6(rawStops.longitudes[raw])
            stopNameRef[newIndex] = rawStops.nameRefs[raw]
            stopCodeRef[newIndex] = rawStops.codeRefs[raw]
            stopIdentifierRef[newIndex] = rawStops.identifierRefs[raw]
            stopPlatformRef[newIndex] = rawStops.platformRefs[raw]
            stopFlags[newIndex] = rawStops.flags[raw]
            stopParentRef[newIndex] = rawStops.parentRefs[raw]
            stopCell[newIndex] = rawCell[raw]
        }

        var stopIndexByIdentifierRef: [UInt32: StopIndex] = [:]
        stopIndexByIdentifierRef.reserveCapacity(stopCount)
        for index in 0..<stopCount where stopIdentifierRef[index] != 0 {
            stopIndexByIdentifierRef[stopIdentifierRef[index]] = Int32(index)
        }

        var stopParent = [Int32](repeating: noIndex, count: stopCount)
        for index in 0..<stopCount {
            let parentRef = stopParentRef[index]
            guard parentRef != 0, let parent = stopIndexByIdentifierRef[parentRef], parent != Int32(index) else {
                continue
            }
            stopParent[index] = parent
        }

        var stopIdentifierMap = rawStops.identifierMap
        stopIdentifierMap.remapValues(newIndexOfRaw)

        func coordinate(_ stop: Int32) -> GeoPoint {
            GeoPoint(latitude: stopLatitude[Int(stop)], longitude: stopLongitude[Int(stop)])
        }

        emit(.stops, 1, "\(stopCount) stops")
        try checkCancellation()

        // MARK: Calendar

        emit(.calendar, 0, "Expanding the service calendar")
        let calendarRows = try readTable("calendar.txt", in: archive, required: false, { reader in
            GTFSTables.readCalendar(&reader, strings: &self.strings)
        }) ?? []
        let exceptionRows = try readTable("calendar_dates.txt", in: archive, required: false, { reader in
            GTFSTables.readCalendarDates(&reader, strings: &self.strings)
        }) ?? []
        let calendar = ServiceCalendarBuilder.build(
            calendars: calendarRows,
            exceptions: exceptionRows,
            window: options.calendarWindow
        )
        if calendar.droppedEmptyServices > 0 {
            report.warnings.append("\(calendar.droppedEmptyServices) services never run in range and were dropped.")
        }
        emit(.calendar, 1, "\(calendar.identifierRefs.count) services over \(calendar.calendarDayCount) days")
        try checkCancellation()

        // MARK: Routes

        emit(.routes, 0, "Reading routes")
        let routes = try readTable("routes.txt", in: archive, required: true, { reader in
            GTFSTables.readRoutes(&reader, strings: &self.strings, agencies: agencies)
        }) ?? GTFSRouteTable()
        emit(.routes, 1, "\(routes.count) routes")
        try checkCancellation()

        // MARK: Trips

        emit(.trips, 0, "Reading trips")
        let trips = try readTable("trips.txt", in: archive, required: true, { reader in
            GTFSTables.readTrips(
                &reader,
                strings: &self.strings,
                report: &self.report,
                routeIndexByRef: routes.indexByIdentifierRef,
                serviceIndexByRef: calendar.indexByServiceRef
            )
        }) ?? GTFSTripTable()
        guard trips.count > 0 else { throw GTFSImportError.noUsableTrips }

        let frequencyRows = try readTable("frequencies.txt", in: archive, required: false, { reader in
            GTFSTables.readFrequencies(&reader, strings: &self.strings)
        }) ?? []
        var frequenciesByTrip: [TripIndex: [GTFSFrequencyRow]] = [:]
        for row in frequencyRows {
            guard let trip = trips.indexByIdentifierRef[row.tripRef] else { continue }
            frequenciesByTrip[trip, default: []].append(row)
        }
        emit(.trips, 1, "\(trips.count) trips")
        try checkCancellation()

        // MARK: Stop times

        emit(.stopTimes, 0, "Reading stop times")
        var stopTimeRows = GTFSStopTimeRows()
        _ = try readTable("stop_times.txt", in: archive, required: true, { reader -> Bool in
            GTFSTables.readStopTimes(
                &reader,
                report: &self.report,
                trips: trips.identifierMap,
                stops: stopIdentifierMap,
                into: &stopTimeRows,
                progress: { fraction in self.emit(.stopTimes, fraction, "Reading stop times") }
            )
            return true
        })
        let stopTimeRowCount = stopTimeRows.count
        guard stopTimeRowCount > 0 else { throw GTFSImportError.noUsableTrips }
        try checkCancellation()

        // Counting sort into trip order. GTFS does not guarantee `stop_times.txt`
        // is grouped by trip, and a comparison sort of every row to make it so
        // would cost more than the parse; this is one linear pass either way.
        var tripRowStart = [Int](repeating: 0, count: trips.count + 1)
        for trip in stopTimeRows.trips where trip >= 0 && Int(trip) < trips.count {
            tripRowStart[Int(trip) + 1] += 1
        }
        for trip in 0..<trips.count {
            tripRowStart[trip + 1] += tripRowStart[trip]
        }
        var fillCursor = tripRowStart
        var rowOrder = [Int32](repeating: 0, count: stopTimeRowCount)
        for row in 0..<stopTimeRowCount {
            let trip = Int(stopTimeRows.trips[row])
            guard trip >= 0, trip < trips.count else { continue }
            rowOrder[fillCursor[trip]] = Int32(row)
            fillCursor[trip] += 1
        }

        // MARK: Trip assembly

        let patternBuilder = PatternBuilder()
        var inexactTrips = Set<TripIndex>()
        var unanchoredTrips = 0
        var frequencyTrips = 0

        var tripStops: [StopIndex] = []
        var tripPickups: [UInt8] = []
        var tripDropOffs: [UInt8] = []
        var tripArrivals: [ServiceSeconds] = []
        var tripDepartures: [ServiceSeconds] = []
        var cumulativeMeters: [Double] = []
        var slice: [Int32] = []

        for trip in 0..<trips.count {
            if trip & 0x3FFF == 0 { try checkCancellation() }

            let lower = tripRowStart[trip]
            let upper = tripRowStart[trip + 1]
            let positionCount = upper - lower
            guard positionCount >= 2 else {
                if positionCount > 0 { report.droppedTripsTooShort += 1 }
                continue
            }

            slice.removeAll(keepingCapacity: true)
            slice.append(contentsOf: rowOrder[lower..<upper])
            var sorted = true
            for position in 1..<positionCount
            where stopTimeRows.sequences[Int(slice[position - 1])] > stopTimeRows.sequences[Int(slice[position])] {
                sorted = false
                break
            }
            if !sorted {
                slice.sort { stopTimeRows.sequences[Int($0)] < stopTimeRows.sequences[Int($1)] }
            }

            tripStops.removeAll(keepingCapacity: true)
            tripPickups.removeAll(keepingCapacity: true)
            tripDropOffs.removeAll(keepingCapacity: true)
            tripArrivals.removeAll(keepingCapacity: true)
            tripDepartures.removeAll(keepingCapacity: true)
            for row in slice {
                let index = Int(row)
                tripStops.append(stopTimeRows.stops[index])
                tripPickups.append(stopTimeRows.pickups[index])
                tripDropOffs.append(stopTimeRows.dropOffs[index])
                tripArrivals.append(stopTimeRows.arrivals[index])
                tripDepartures.append(stopTimeRows.departures[index])
            }

            // GTFS allows either half of the pair to be blank, meaning "the same
            // as the other one" — a stop the vehicle does not dwell at.
            for position in 0..<positionCount {
                if tripArrivals[position] == noTime, tripDepartures[position] != noTime {
                    tripArrivals[position] = tripDepartures[position]
                } else if tripDepartures[position] == noTime, tripArrivals[position] != noTime {
                    tripDepartures[position] = tripArrivals[position]
                }
            }

            // An untimed first or last stop cannot be anchored to anything, and
            // guessing would put a departure in the timetable that no vehicle makes.
            guard tripArrivals[0] != noTime, tripArrivals[positionCount - 1] != noTime else {
                unanchoredTrips += 1
                report.droppedTripsTooShort += 1
                continue
            }

            cumulativeMeters.removeAll(keepingCapacity: true)
            cumulativeMeters.append(0)
            for position in 1..<positionCount {
                let step = coordinate(tripStops[position - 1]).approximateDistance(to: coordinate(tripStops[position]))
                cumulativeMeters.append(cumulativeMeters[position - 1] + (step.isFinite ? step : 0))
            }

            var position = 1
            var lastTimed = 0
            while position < positionCount {
                guard tripArrivals[position] == noTime else {
                    lastTimed = position
                    position += 1
                    continue
                }
                var next = position + 1
                while next < positionCount, tripArrivals[next] == noTime { next += 1 }
                guard next < positionCount else { break }

                let startSeconds = Double(tripDepartures[lastTimed])
                let endSeconds = Double(tripArrivals[next])
                let span = cumulativeMeters[next] - cumulativeMeters[lastTimed]
                for blank in position..<next {
                    let fraction: Double
                    if span > 0 {
                        fraction = (cumulativeMeters[blank] - cumulativeMeters[lastTimed]) / span
                    } else {
                        // Coincident coordinates: fall back to even spacing.
                        fraction = Double(blank - lastTimed) / Double(next - lastTimed)
                    }
                    let interpolated = ServiceSeconds(
                        (startSeconds + fraction * (endSeconds - startSeconds)).rounded()
                    )
                    tripArrivals[blank] = interpolated
                    tripDepartures[blank] = interpolated
                    report.interpolatedStopTimes += 1
                }
                lastTimed = next
                position = next + 1
            }

            let sourceTrip = TripIndex(trip)
            let route = trips.routeIndices[trip]

            if let frequencies = frequenciesByTrip[sourceTrip], !frequencies.isEmpty {
                let anchor = tripDepartures[0]
                var generated = 0
                for frequency in frequencies {
                    guard frequency.headwaySeconds > 0, frequency.endTime >= frequency.startTime else { continue }
                    if !frequency.exactTimes { inexactTrips.insert(sourceTrip) }
                    var departure = frequency.startTime
                    while generated < 500 {
                        if departure > frequency.endTime { break }
                        if departure == frequency.endTime, frequency.startTime != frequency.endTime { break }
                        let shift = departure - anchor
                        var shiftedArrivals = tripArrivals
                        var shiftedDepartures = tripDepartures
                        for index in 0..<positionCount {
                            shiftedArrivals[index] &+= shift
                            shiftedDepartures[index] &+= shift
                        }
                        patternBuilder.add(
                            sourceTrip: sourceTrip,
                            route: route,
                            stops: tripStops,
                            pickups: tripPickups,
                            dropOffs: tripDropOffs,
                            arrivals: shiftedArrivals,
                            departures: shiftedDepartures
                        )
                        generated += 1
                        departure &+= frequency.headwaySeconds
                    }
                }
                frequencyTrips += generated
                if generated == 0 {
                    patternBuilder.add(
                        sourceTrip: sourceTrip,
                        route: route,
                        stops: tripStops,
                        pickups: tripPickups,
                        dropOffs: tripDropOffs,
                        arrivals: tripArrivals,
                        departures: tripDepartures
                    )
                }
            } else {
                patternBuilder.add(
                    sourceTrip: sourceTrip,
                    route: route,
                    stops: tripStops,
                    pickups: tripPickups,
                    dropOffs: tripDropOffs,
                    arrivals: tripArrivals,
                    departures: tripDepartures
                )
            }
        }

        // The flat stop-time columns are the largest thing in memory; release them
        // before the pattern arrays double up.
        stopTimeRows = GTFSStopTimeRows()
        rowOrder = []

        if unanchoredTrips > 0 {
            report.warnings.append("\(unanchoredTrips) trips had no time at their first or last stop and were dropped.")
        }
        if frequencyTrips > 0 {
            report.warnings.append("\(frequencyTrips) trips were expanded from frequencies.txt.")
        }

        emit(.buildingPatterns, 0, "Grouping trips into patterns")
        try checkCancellation()
        let patternResult = patternBuilder.finish()
        guard !patternResult.patterns.isEmpty else { throw GTFSImportError.noUsableTrips }
        if patternResult.overtakingSplits > 0 {
            report.warnings.append("\(patternResult.overtakingSplits) patterns were split because trips overtake.")
        }
        emit(.buildingPatterns, 1, "\(patternResult.patterns.count) patterns")

        // MARK: Pattern, trip and stop-time columns

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

        for pattern in patternResult.patterns {
            let positionCount = pattern.stops.count
            let tripCount = pattern.sourceTrips.count
            guard positionCount >= 2, tripCount > 0 else { continue }
            // Positions are stored as UInt16 in the stop→pattern index.
            guard positionCount <= Int(UInt16.max) else {
                report.warnings.append("Dropped a pattern with \(positionCount) stops; the index caps at 65535.")
                continue
            }
            let firstTrip = Int(pattern.sourceTrips[0])
            guard firstTrip >= 0, firstTrip < trips.count else { continue }

            patternRoute.append(pattern.route)
            patternStopStart.append(UInt32(patternStopReference.count))
            patternStopCount.append(UInt32(positionCount))
            patternTripStart.append(UInt32(tripService.count))
            patternTripCount.append(UInt32(tripCount))
            patternStopTimeStart.append(UInt32(stopTimeArrival.count))
            patternHeadsign.append(trips.headsignRefs[firstTrip])
            patternDirection.append(trips.directions[firstTrip])

            // A pattern only claims an accessibility guarantee its every trip
            // makes; one unknown trip makes the whole pattern unknown.
            var wheelchair = trips.flags[firstTrip] & 0b11
            var bicycles = (trips.flags[firstTrip] >> 2) & 0b11
            var inexact = false
            for source in pattern.sourceTrips {
                let index = Int(source)
                guard index >= 0, index < trips.count else { continue }
                if trips.flags[index] & 0b11 != wheelchair { wheelchair = AccessibilityFlag.unknown.rawValue }
                if (trips.flags[index] >> 2) & 0b11 != bicycles { bicycles = AccessibilityFlag.unknown.rawValue }
                if inexactTrips.contains(source) { inexact = true }
            }
            // Bit 4 records "frequency-based with exact_times = 0", i.e. the
            // timetable is a headway promise rather than a clock time.
            patternFlags.append(wheelchair | (bicycles << 2) | (inexact ? 0b1_0000 : 0))

            var cumulative = 0.0
            for position in 0..<positionCount {
                let stop = pattern.stops[position]
                patternStopReference.append(stop)
                patternPickup.append(pattern.pickups[position])
                patternDropOff.append(pattern.dropOffs[position])
                if position > 0 {
                    let step = coordinate(pattern.stops[position - 1]).approximateDistance(to: coordinate(stop))
                    if step.isFinite { cumulative += step }
                }
                patternStopDistance.append(GTFSImporter.meterInt(cumulative))
            }

            for offset in 0..<tripCount {
                // Never skip: `patternTripCount` has already been written, and a
                // short trip block would desynchronise every later pattern's
                // stop-time base.
                let raw = Int(pattern.sourceTrips[offset])
                let source = (raw >= 0 && raw < trips.count) ? raw : firstTrip
                tripService.append(trips.serviceIndices[source])
                tripIdentifier.append(trips.identifierRefs[source])
                tripHeadsign.append(trips.headsignRefs[source])
                tripShortName.append(trips.shortNameRefs[source])
                tripFlags.append(trips.flags[source])
                let base = offset * positionCount
                stopTimeArrival.append(contentsOf: pattern.arrivals[base ..< (base + positionCount)])
                stopTimeDeparture.append(contentsOf: pattern.departures[base ..< (base + positionCount)])
            }
        }

        let patternCount = patternRoute.count
        guard patternCount > 0 else { throw GTFSImportError.noUsableTrips }

        // MARK: Transfers

        emit(.buildingTransfers, 0, "Building footpaths")
        try checkCancellation()

        let transferRows = try readTable("transfers.txt", in: archive, required: false, { reader in
            GTFSTables.readTransfers(&reader, strings: &self.strings)
        }) ?? []
        var seeds: [TransferBuilder.Seed] = []
        seeds.reserveCapacity(transferRows.count)
        for row in transferRows {
            guard let from = stopIndexByIdentifierRef[row.fromStopRef],
                  let to = stopIndexByIdentifierRef[row.toStopRef]
            else {
                report.droppedTransfersUnknownStop += 1
                continue
            }
            seeds.append(
                TransferBuilder.Seed(
                    from: from,
                    to: to,
                    seconds: row.minimumSeconds,
                    isForbidden: row.type == 3
                )
            )
        }

        var coordinates = [GeoPoint](repeating: GeoPoint(latitude: 0, longitude: 0), count: stopCount)
        var isStation = [Bool](repeating: false, count: stopCount)
        for index in 0..<stopCount {
            coordinates[index] = GeoPoint(latitude: stopLatitude[index], longitude: stopLongitude[index])
            isStation[index] = stopFlags[index] & 0b100 != 0
        }

        let transfers = TransferBuilder.build(
            coordinates: coordinates,
            isStation: isStation,
            parents: stopParent,
            seeds: seeds,
            options: options.buildOptions
        )
        if transfers.forbiddenPairs > 0 {
            report.warnings.append("\(transfers.forbiddenPairs) transfers are forbidden by the feed and were excluded.")
        }
        emit(.buildingTransfers, 1, "\(transfers.targets.count) footpaths")
        try checkCancellation()

        // MARK: Stop → pattern index

        emit(.buildingIndex, 0, "Indexing stops")
        var stopPatternCount = [UInt32](repeating: 0, count: stopCount)
        for pattern in 0..<patternCount {
            let base = Int(patternStopStart[pattern])
            for position in 0..<Int(patternStopCount[pattern]) {
                stopPatternCount[Int(patternStopReference[base + position])] += 1
            }
        }
        var stopPatternStart = [UInt32](repeating: 0, count: stopCount)
        var runningSlot = 0
        for stop in 0..<stopCount {
            stopPatternStart[stop] = UInt32(runningSlot)
            runningSlot += Int(stopPatternCount[stop])
        }
        var stopPatternReference = [Int32](repeating: 0, count: runningSlot)
        var stopPatternPosition = [UInt16](repeating: 0, count: runningSlot)
        var slotCursor = stopPatternStart
        for pattern in 0..<patternCount {
            let base = Int(patternStopStart[pattern])
            for position in 0..<Int(patternStopCount[pattern]) {
                let stop = Int(patternStopReference[base + position])
                let slot = Int(slotCursor[stop])
                slotCursor[stop] += 1
                stopPatternReference[slot] = Int32(pattern)
                stopPatternPosition[slot] = UInt16(position)
            }
        }

        // MARK: Spatial grid

        let cellCount = grid.rows * grid.columns
        var gridCellCount = [UInt32](repeating: 0, count: cellCount)
        var gridStopReference = [Int32](repeating: 0, count: stopCount)
        for stop in 0..<stopCount {
            gridStopReference[stop] = Int32(stop)
            let cell = Int(stopCell[stop])
            if cell >= 0, cell < cellCount { gridCellCount[cell] += 1 }
        }
        var gridCellStart = [UInt32](repeating: 0, count: cellCount)
        var runningCell = 0
        for cell in 0..<cellCount {
            gridCellStart[cell] = UInt32(runningCell)
            runningCell += Int(gridCellCount[cell])
        }
        emit(.buildingIndex, 1, "Index built")
        try checkCancellation()

        // MARK: Metadata

        var feedVersion = ""
        if let declared = try readTable("feed_info.txt", in: archive, required: false, { reader in
            GTFSTables.readFeedVersion(&reader)
        }) {
            feedVersion = declared
        }
        if feedVersion.isEmpty { feedVersion = GTFSImporter.fingerprint(of: archive) }

        var metadata = GraphMetadata()
        metadata.feedIdentifier = options.feedIdentifier
        metadata.feedName = options.feedName
        metadata.feedVersion = feedVersion
        metadata.sourceURL = options.sourceURL
        metadata.builtAt = Date()
        metadata.timeZoneIdentifier = timeZoneIdentifier
        metadata.calendarStart = calendar.calendarStart
        metadata.calendarDayCount = calendar.calendarDayCount
        metadata.serviceBitsetStride = calendar.bitsetStride
        metadata.counts.stops = stopCount
        metadata.counts.patterns = patternCount
        metadata.counts.trips = tripService.count
        metadata.counts.stopTimes = stopTimeArrival.count
        metadata.counts.routes = routes.count
        metadata.counts.agencies = agencies.count
        metadata.counts.services = calendar.identifierRefs.count
        metadata.counts.transfers = transfers.targets.count
        metadata.bounds = bounds
        metadata.grid = grid
        metadata.buildOptions = options.buildOptions
        metadata.report = report

        // MARK: Write

        emit(.writing, 0, "Writing the graph")
        let writer = try TransitGraphWriter(url: destination)
        do {
            try writer.append(.stopLatitudeE6, stopLatitudeE6)
            try writer.append(.stopLongitudeE6, stopLongitudeE6)
            try writer.append(.stopName, stopNameRef)
            try writer.append(.stopCode, stopCodeRef)
            try writer.append(.stopIdentifier, stopIdentifierRef)
            try writer.append(.stopPlatformCode, stopPlatformRef)
            try writer.append(.stopParent, stopParent)
            try writer.append(.stopFlags, stopFlags)
            try writer.append(.stopPatternStart, stopPatternStart)
            try writer.append(.stopPatternCount, stopPatternCount)
            try writer.append(.stopPatternReference, stopPatternReference)
            try writer.append(.stopPatternPosition, stopPatternPosition)
            try writer.append(.stopTransferStart, transfers.starts)
            try writer.append(.stopTransferCount, transfers.counts)

            try writer.append(.transferTarget, transfers.targets)
            try writer.append(.transferSeconds, transfers.seconds)
            try writer.append(.transferMeters, transfers.meters)

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

            try writer.append(.routeShortName, routes.shortNameRefs)
            try writer.append(.routeLongName, routes.longNameRefs)
            try writer.append(.routeIdentifier, routes.identifierRefs)
            try writer.append(.routeDescription, routes.descriptionRefs)
            try writer.append(.routeType, routes.types)
            try writer.append(.routeColor, routes.colors)
            try writer.append(.routeTextColor, routes.textColors)
            try writer.append(.routeAgency, routes.agencies)

            try writer.append(.agencyName, agencies.nameRefs)
            try writer.append(.agencyIdentifier, agencies.identifierRefs)
            try writer.append(.agencyURL, agencies.urlRefs)
            try writer.append(.agencyTimeZone, agencies.timeZoneRefs)

            try writer.append(.serviceBits, calendar.bits)
            try writer.append(.serviceIdentifier, calendar.identifierRefs)

            try writer.append(.gridCellStart, gridCellStart)
            try writer.append(.gridCellCount, gridCellCount)
            try writer.append(.gridStopReference, gridStopReference)

            try writer.appendBytes(.stringBlob, strings.finish())
            try writer.finish(metadata: metadata)
        } catch {
            writer.discard()
            throw error
        }
        emit(.writing, 1, "Graph written")

        // MARK: Verify
        //
        // Reading back what was just written is cheap next to the compile and
        // turns a silent index bug into a failed install rather than a wrong
        // journey three weeks later.
        emit(.verifying, 0, "Verifying the graph")
        do {
            let graph = try TransitGraph.open(contentsOf: destination)
            guard graph.stopCount == stopCount,
                  graph.patternCount == patternCount,
                  graph.tripCount == metadata.counts.trips,
                  graph.transferCount == metadata.counts.transfers
            else {
                throw GraphError.malformedSection(.metadata, reason: "counts disagree with the written columns")
            }
        } catch {
            throw GTFSImportError.archive("the compiled graph failed verification: \(error.localizedDescription)")
        }
        emit(.verifying, 1, "Done")

        return metadata
    }

    // MARK: - Reading

    /// Opens one CSV member of the archive and hands the reader to `parse`.
    ///
    /// A malformed *optional* table is a warning, not a failure: a feed with a
    /// broken `transfers.txt` is still a perfectly routable feed.
    private func readTable<R>(
        _ name: String,
        in archive: ZipArchive,
        required: Bool,
        _ parse: (inout CSVReader) throws -> R
    ) throws -> R? {
        guard let entry = archive.entry(named: name) else {
            if required { throw GTFSImportError.missingRequiredFile(name) }
            return nil
        }
        do {
            return try archive.withBytes(of: entry) { bytes -> R in
                var reader = try CSVReader(bytes: bytes)
                return try parse(&reader)
            }
        } catch let error as GTFSImportError {
            throw error
        } catch {
            if required { throw GTFSImportError.archive("\(name): \(error.localizedDescription)") }
            report.warnings.append("Skipped \(name): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Grid

    /// Roughly 300 m cells, which is small enough that a 500 m nearby scan touches
    /// a handful of cells and large enough that a national feed does not spend
    /// more memory on empty cells than on stops.
    private static let targetCellMeters = 300.0
    private static let maximumCellCount = 1_000_000

    static func makeGrid(bounds: GeoBounds) -> GraphMetadata.Grid {
        guard !bounds.isEmpty else { return .empty }

        // Nudged below the minimum so a stop sitting exactly on the edge cannot
        // round to row -1 and fall out of the grid.
        let originLatitude = bounds.minLatitude - 1e-7
        let originLongitude = bounds.minLongitude - 1e-7

        var latitudeSpan = GeoPoint.latitudeDegrees(forMeters: targetCellMeters)
        if !latitudeSpan.isFinite || latitudeSpan <= 0 { latitudeSpan = 0.0027 }
        var longitudeSpan = bounds.center.longitudeDegrees(forMeters: targetCellMeters)
        if !longitudeSpan.isFinite || longitudeSpan <= 0 { longitudeSpan = latitudeSpan }
        longitudeSpan = min(longitudeSpan, 10)

        var rows = 1
        var columns = 1
        for _ in 0..<40 {
            rows = max(1, Int(((bounds.maxLatitude - originLatitude) / latitudeSpan).rounded(.down)) + 1)
            columns = max(1, Int(((bounds.maxLongitude - originLongitude) / longitudeSpan).rounded(.down)) + 1)
            if rows * columns <= maximumCellCount { break }
            latitudeSpan *= 2
            longitudeSpan *= 2
        }

        return GraphMetadata.Grid(
            originLatitude: originLatitude,
            originLongitude: originLongitude,
            cellLatitudeSpan: latitudeSpan,
            cellLongitudeSpan: longitudeSpan,
            columns: columns,
            rows: rows
        )
    }

    static func cellIndex(_ grid: GraphMetadata.Grid, latitude: Double, longitude: Double) -> Int {
        guard grid.rows > 0, grid.columns > 0 else { return 0 }
        let row = min(max(0, grid.row(forLatitude: latitude)), grid.rows - 1)
        let column = min(max(0, grid.column(forLongitude: longitude)), grid.columns - 1)
        return row * grid.columns + column
    }

    private static func meterInt(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(min(max(value.rounded(), 0), 2_000_000_000))
    }

    /// Content fingerprint of the archive, used as `feedVersion` when the feed
    /// omits `feed_info.txt`. Built from the central directory's CRCs rather than
    /// the bytes: same discriminating power, none of the I/O.
    private static func fingerprint(of archive: ZipArchive) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for entry in archive.entries.sorted(by: { $0.name < $1.name }) {
            for byte in entry.name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            hash = (hash ^ UInt64(entry.crc32)) &* 0x0000_0100_0000_01b3
            hash = (hash ^ UInt64(UInt32(truncatingIfNeeded: entry.uncompressedSize)))
                &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Progress and cancellation

    /// Shares of the overall bar. `stopTimes` dominates because on a real feed it
    /// is 95% of the rows.
    private static let phaseWeights: [Double] = [
        0.02, 0.02, 0.06, 0.02, 0.04, 0.06, 0.40, 0.12, 0.14, 0.04, 0.06, 0.02,
    ]

    private func emit(_ phase: GTFSImportPhase, _ fraction: Double, _ detail: String) {
        guard let onProgress else { return }
        let clamped = min(max(fraction, 0), 1)
        var completed = 0.0
        var weight = 0.0
        for (index, candidate) in GTFSImportPhase.allCases.enumerated() {
            let value = index < GTFSImporter.phaseWeights.count ? GTFSImporter.phaseWeights[index] : 0
            if candidate == phase {
                weight = value
                break
            }
            completed += value
        }
        onProgress(
            GTFSImportProgress(
                phase: phase,
                fractionCompleted: clamped,
                overallFraction: min(1, completed + weight * clamped),
                detail: detail
            )
        )
    }

    private func checkCancellation() throws {
        if isCancelled?() == true { throw GTFSImportError.cancelled }
    }
}
