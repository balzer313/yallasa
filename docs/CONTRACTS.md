# Module contracts

This file is normative. Every module in `YallaSaKit` is written against the
signatures below, and nothing outside a module may depend on anything not listed
here. If an implementation needs a different signature, this file changes first.

Types marked **[fixed]** already exist in the repository — read the actual source
rather than reimplementing them:

| Type | File |
|---|---|
| `StopIndex`, `PatternIndex`, `RouteIndex`, `TripIndex`, `ServiceIndex`, `AgencyIndex`, `noIndex`, `ServiceSeconds`, `noTime` | `Core/Indices.swift` |
| `GeoPoint`, `GeoBounds` | `Core/GeoPoint.swift` |
| `ServiceDate`, `ServiceInstant`, `parseGTFSTime` | `Core/ServiceDate.swift` |
| `TransitMode`, `StopServiceAvailability`, `AccessibilityFlag` | `Core/RouteType.swift` |
| `GraphFormat`, `GraphSection`, `GraphSectionDescriptor`, `GraphMetadata`, `GraphError` | `Graph/GraphFormat.swift` |
| `GraphMemory` | `Graph/GraphMemory.swift` |
| `TransitGraph`, `NearbyStop` | `Graph/TransitGraph.swift` |
| `TransitGraphWriter`, `StringTableBuilder` | `Graph/TransitGraphWriter.swift` |
| `PlanEndpoint`, `PlanTimeAnchor`, `PlanOptions`, `PlanRequest`, `LegPoint`, `WalkLeg`, `RideLeg`, `JourneyLeg`, `Journey`, `PlanStatistics`, `PlanResult`, `PlanError`, `Departure` | `Routing/PlanTypes.swift` |
| `RealtimeAdjustment`, `RealtimeSource`, `EmptyRealtimeSource`, `ServiceAlert` | `Realtime/RealtimeSource.swift` |

## Global rules

1. **No third-party dependencies.** Foundation, Compression, os, and on the app
   side SwiftUI/MapKit/CoreLocation. Nothing else.
2. **No force unwraps and no `try!` on anything derived from feed data.** Feeds
   are dirty. Malformed input drops a row and increments a counter in
   `GraphMetadata.ImportReport`; it never crashes and never throws away the feed.
3. **Public API is documented; private helpers are not, unless the reason for
   their existence is non-obvious.** Comments explain *why*, never *what*.
4. **Every type crossing a concurrency boundary is `Sendable`.** The engine is
   used from a background queue and its results are consumed on the main actor.
5. **Times are `ServiceSeconds` in a named day frame.** Never `TimeInterval`,
   never a bare `Date`, until the display boundary.
6. Files live under `Sources/YallaSaKit/<Area>/`; tests under
   `Tests/YallaSaKitTests/<Area>/`.

---

## 1. IO — `Sources/YallaSaKit/IO/`

### `ZipArchive`

```swift
public struct ZipEntry: Hashable, Sendable {
    public var name: String            // full path as stored in the archive
    public var baseName: String        // last path component, lowercased
    public var compressedSize: Int
    public var uncompressedSize: Int
    public var crc32: UInt32
    public var compressionMethod: UInt16   // 0 = stored, 8 = deflate
    public var localHeaderOffset: Int
}

public final class ZipArchive {
    public init(url: URL) throws
    public var entries: [ZipEntry] { get }

    /// Case-insensitive match on the *base* name. GTFS archives are routinely
    /// published with every file inside a top-level folder, so matching the full
    /// path fails on perfectly valid feeds.
    public func entry(named name: String) -> ZipEntry?

    /// Inflates an entry fully into memory.
    public func data(for entry: ZipEntry) throws -> Data

    /// Inflates and yields the bytes without an extra copy. Preferred for the
    /// large tables; `body` must not escape the pointer.
    public func withBytes<R>(of entry: ZipEntry, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R
}

public enum ZipError: Error, LocalizedError, Equatable {
    case notAZipArchive
    case unsupportedCompression(UInt16)
    case corruptCentralDirectory(String)
    case entryTooLarge(Int)
    case inflateFailed(String)
    case checksumMismatch(entry: String)
}
```

Requirements: read the End Of Central Directory record by scanning backwards
over the last 64 KB; support the ZIP64 EOCD locator; support stored and deflate;
verify CRC-32 on decompress and throw `.checksumMismatch` on failure. Use
`Compression`'s `COMPRESSION_ZLIB` in raw-deflate mode via
`compression_stream_process`; do not shell out and do not vendor zlib.

### `CSVReader`

```swift
/// A forward-only RFC 4180 reader over a raw byte buffer.
///
/// Fields are returned as pointers into the source (or into a per-row scratch
/// buffer when unescaping was required) and are valid only until the next call
/// to `next()`. `stop_times.txt` in a metro feed has millions of rows; a reader
/// that allocated a `[String]` per row would spend the entire import budget in
/// the allocator.
public struct CSVReader {
    public init(bytes: UnsafeRawBufferPointer) throws
    public var header: [String] { get }
    public func columnIndex(_ name: String) -> Int?
    public mutating func next() -> CSVRow?
    public var rowsRead: Int { get }
    public var approximateProgress: Double { get }   // 0...1 by bytes consumed
}

public struct CSVRow {
    public var fieldCount: Int { get }
    public func bytes(_ column: Int) -> UnsafeBufferPointer<UInt8>   // empty if out of range
    public func string(_ column: Int) -> String
    public func int(_ column: Int) -> Int?
    public func double(_ column: Int) -> Double?
    public func isEmpty(_ column: Int) -> Bool
}

public enum CSVError: Error, Equatable { case emptyFile, malformedHeader }
```

Requirements: strip a UTF-8 BOM; accept `\n` and `\r\n`; handle quoted fields
containing commas, newlines and doubled quotes; tolerate rows with fewer or more
fields than the header (short rows report empty for missing columns); tolerate a
missing trailing newline. Header names are matched case-insensitively and with
surrounding whitespace trimmed, because real feeds contain both.

---

## 2. GTFS import — `Sources/YallaSaKit/GTFS/`

```swift
public struct GTFSImportOptions: Sendable {
    public var feedIdentifier: String
    public var feedName: String
    public var sourceURL: String
    public var buildOptions: GraphMetadata.BuildOptions
    /// Clip the feed to a region. Nil imports everything.
    public var boundingBox: GeoBounds?
    /// Service days to keep. Nil keeps the feed's own range, capped at 400 days.
    public var calendarWindow: ClosedRange<ServiceDate>?
    public init(feedIdentifier: String, feedName: String, sourceURL: String)
}

public enum GTFSImportPhase: String, Sendable, CaseIterable {
    case openingArchive, agencies, stops, routes, calendar, trips, stopTimes,
         buildingPatterns, buildingTransfers, buildingIndex, writing, verifying
}

public struct GTFSImportProgress: Sendable {
    public var phase: GTFSImportPhase
    public var fractionCompleted: Double    // 0...1 within the phase
    public var overallFraction: Double      // 0...1 across the whole import
    public var detail: String
}

public final class GTFSImporter {
    public init(options: GTFSImportOptions)
    public var onProgress: (@Sendable (GTFSImportProgress) -> Void)?
    /// Return true to abort; checked at least once a second.
    public var isCancelled: (@Sendable () -> Bool)?

    /// Compiles a GTFS archive into a graph file. On success the file at
    /// `destination` is a complete, openable graph. On any throw, `destination`
    /// is removed.
    public func compile(archiveAt archive: URL, to destination: URL) throws -> GraphMetadata
}

public enum GTFSImportError: Error, LocalizedError, Equatable {
    case missingRequiredFile(String)
    case noUsableStops
    case noUsableTrips
    case cancelled
    case archive(String)
}
```

### Compilation rules

- **Required files:** `stops.txt`, `routes.txt`, `trips.txt`, `stop_times.txt`,
  and at least one of `calendar.txt` / `calendar_dates.txt`. Anything else is
  optional.
- **Patterns.** Group trips whose ordered `(stop, pickup_type, drop_off_type)`
  sequence is identical *and* whose route matches. Trips within a pattern are
  sorted by departure at position 0. This grouping is what makes RAPTOR work; a
  pattern is its notion of a "route".
- **Overtaking.** If, within a pattern, sorting by first departure does not also
  sort every other position, split the offending trips into a separate pattern.
  RAPTOR's early-exit on trip search assumes monotonicity, and a feed that
  violates it silently produces wrong answers rather than slow ones.
- **Interpolation.** `stop_times` rows with a blank arrival/departure get times
  linearly interpolated by cumulative straight-line distance between the nearest
  bracketing timed stops. Count these in `report.interpolatedStopTimes`.
- **Times.** Parse with `parseGTFSTime`. Values ≥ 86400 are kept as-is — they are
  how GTFS expresses after-midnight service and must not be normalised.
- **Calendar.** Expand `calendar.txt` weekday masks plus `calendar_dates.txt`
  exceptions into one bitset per service over `[calendarStart, +calendarDayCount)`.
  Set `serviceBitsetStride = (calendarDayCount + 7) / 8`. Drop services with no
  active day.
- **Frequencies.** Expand `frequencies.txt` into concrete trips
  (`exact_times = 1` and `0` both expand; the latter is marked in pattern flags).
  Cap expansion at 500 trips per source trip to survive pathological feeds.
- **Transfers.** Seed from `transfers.txt` (`transfer_type` 0/1/2 give a minimum
  time; type 3 forbids and must be recorded as such and excluded). Add generated
  footpaths between every pair of stops within `buildOptions.maxTransferMeters`,
  computed from the spatial grid, with
  `seconds = max(minimumTransferSeconds, distance * detourFactor / walkSpeed)`.
  Then take a bounded transitive closure (Dijkstra from each stop, stopping at
  `maxTransferSeconds`) so RAPTOR's transitively-closed-footpath assumption holds.
  Never emit a self-transfer. Cap out-degree at 32, keeping the nearest.
- **Stations.** `location_type = 1` records become stops with the station flag
  set and are never targets of a pattern. `location_type` 2/3/4 are dropped.
  Child stops of the same parent always get a mutual transfer.
- **Ordering.** Emit stops sorted by grid cell so that spatially adjacent stops
  are adjacent in memory. This is worth roughly 20% on nearby-stop scans.
- **Memory.** Never hold all of `stop_times.txt` as parsed objects. Stream it,
  accumulating into per-trip arrays, and release each trip once its pattern is
  assigned. Peak RSS budget is 250 MB for a 2M-row feed.

---

## 3. Routing — `Sources/YallaSaKit/Routing/`

```swift
public final class JourneyPlanner {
    public init(graph: TransitGraph)
    public func plan(
        _ request: PlanRequest,
        realtime: RealtimeSource = EmptyRealtimeSource.shared
    ) throws -> PlanResult
}

public final class DepartureBoardService {
    public init(graph: TransitGraph)

    /// Upcoming departures across a set of stops, earliest first.
    public func departures(
        from stops: [StopIndex],
        after instant: ServiceInstant,
        withinSeconds window: Int,
        limit: Int,
        limitPerPattern: Int,
        modes: Set<TransitMode>?,
        realtime: RealtimeSource
    ) -> [Departure]

    /// Every departure of one pattern from one stop — a line's timetable.
    public func departures(
        pattern: PatternIndex,
        at position: Int,
        on date: ServiceDate,
        realtime: RealtimeSource
    ) -> [Departure]
}
```

### Algorithm requirements

- RAPTOR, round-based, `maximumTransfers + 1` rounds.
- Three service-day offsets (−1, 0, +1) are considered for every trip lookup, so
  after-midnight and before-dawn service resolve correctly.
- Range-RAPTOR over the departure window for multiple results; the returned set
  must be Pareto-optimal on (departure time, arrival time, transfer count) with
  dominated options removed.
- Arrive-by runs the mirrored search backwards from the destination.
- Access and egress legs come from `graph.stops(near:radiusMeters:)`.
- The `timeLimitSeconds` budget is honoured: on expiry return the best results
  found so far with `statistics.hitTimeLimit = true`, never an empty result.
- The planner must be usable concurrently from several tasks on one graph, so all
  scratch arrays live in a per-query context, not in the planner.

---

## 4. Realtime — `Sources/YallaSaKit/Realtime/`

```swift
public enum ProtobufWireType: UInt8 { case varint, fixed64, lengthDelimited, startGroup, endGroup, fixed32 }

public struct ProtobufReader {
    public init(bytes: UnsafeRawBufferPointer)
    public mutating func nextField() throws -> (number: Int, wireType: ProtobufWireType)?
    public mutating func readVarint() throws -> UInt64
    public mutating func readFixed32() throws -> UInt32
    public mutating func readFixed64() throws -> UInt64
    public mutating func readLengthDelimited() throws -> UnsafeRawBufferPointer
    public mutating func skipField(wireType: ProtobufWireType) throws
}

public struct GTFSRealtimeFeed: Sendable {
    public var generatedAt: Date
    public var tripUpdates: [RTTripUpdate]
    public var vehiclePositions: [RTVehiclePosition]
    public var alerts: [RTAlert]
}

public enum GTFSRealtimeDecoder {
    public static func decode(_ data: Data) throws -> GTFSRealtimeFeed
}

/// Resolves a decoded feed against a graph once, then answers by index.
public final class RealtimeIndex: RealtimeSource {
    public init(feed: GTFSRealtimeFeed, graph: TransitGraph, referenceDate: ServiceDate)
    public var alerts: [ServiceAlert] { get }
    public var unmatchedTripCount: Int { get }
}
```

Decode only the fields that are used: `FeedHeader.timestamp`,
`TripUpdate.trip{trip_id, route_id, start_date, schedule_relationship}`,
`TripUpdate.stop_time_update{stop_sequence, stop_id, arrival.delay, arrival.time,
departure.delay, departure.time, schedule_relationship}`, `VehiclePosition`
position/bearing/timestamp, and `Alert` texts, effect, cause, active periods and
informed entities. Skip everything else by wire type. A field the decoder does
not know must never fail the parse — realtime feeds add fields without notice.

When a stop-time update supplies an absolute `time` rather than a `delay`, derive
the delay against the scheduled time from the graph. Propagate the last known
delay forward to later stops of the same trip, which is what every reference
implementation does and what riders expect.

---

## 5. Feeds — `Sources/YallaSaKit/Feeds/`

```swift
public struct FeedSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var region: String
    public var countryCode: String
    public var staticURL: URL
    public var realtimeTripUpdatesURL: URL?
    public var realtimeAlertsURL: URL?
    public var requestHeaders: [String: String]
    public var attribution: String
    public var licenseURL: URL?
    public var approximateDownloadMegabytes: Int
    public var bounds: GeoBounds?
    public var defaultBoundingBox: GeoBounds?
}

public enum FeedCatalog {
    /// Feeds that need no API key and no registration.
    public static let bundled: [FeedSource]
    public static func nearest(to point: GeoPoint) -> [FeedSource]
}

public struct InstalledFeed: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var source: FeedSource
    public var graphFileName: String
    public var installedAt: Date
    public var metadata: GraphMetadata
    public var byteSize: Int64
}

public actor FeedManager {
    public init(directory: URL) throws
    public var installedFeeds: [InstalledFeed] { get }
    public var activeFeedID: String? { get }

    public func install(_ source: FeedSource, region: GeoBounds?,
                        progress: @Sendable @escaping (FeedInstallProgress) -> Void) async throws -> InstalledFeed
    public func activate(_ feedID: String) async throws -> TransitGraph
    public func remove(_ feedID: String) async throws
    public func refreshIfNeeded(_ feedID: String, maximumAge: TimeInterval,
                                progress: @Sendable @escaping (FeedInstallProgress) -> Void) async throws -> Bool
}

public enum FeedInstallStage: Sendable { case downloading, compiling, installing, done }
public struct FeedInstallProgress: Sendable {
    public var stage: FeedInstallStage
    public var fraction: Double
    public var detail: String
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
}
```

Install is atomic: download to a temp file, compile to
`<feedID>-<timestamp>.mvtg.tmp`, then `FileManager.replaceItem` into place and
rewrite the manifest. A crash at any point leaves either the previous graph or no
graph — never a partial one. Downloaded archives are kept so a format-version
bump can recompile without re-downloading, subject to a disk budget.

---

## 6. App-facing facade — `Sources/YallaSaKit/TransitService.swift`

The app never touches `JourneyPlanner`, `TransitGraph` or `FeedManager` directly.

```swift
@MainActor
public final class TransitService: ObservableObject {
    public static let shared: TransitService

    @Published public private(set) var state: TransitServiceState
    @Published public private(set) var installProgress: FeedInstallProgress?
    @Published public private(set) var realtimeUpdatedAt: Date?

    public var graph: TransitGraph? { get }
    public var timeZone: TimeZone { get }

    public func bootstrap() async
    public func install(_ source: FeedSource, region: GeoBounds?) async throws
    public func activate(feedID: String) async throws
    public func removeFeed(id: String) async throws

    public func plan(_ request: PlanRequest) async throws -> PlanResult
    public func departures(near point: GeoPoint, radius: Double, limit: Int) async -> [Departure]
    public func departures(atStop stop: StopIndex, limit: Int) async -> [Departure]
    public func startRealtimePolling(interval: TimeInterval)
    public func stopRealtimePolling()
}

public enum TransitServiceState: Equatable, Sendable {
    case idle, needsFeed, installing, ready, failed(String)
}
```

Planning and departure computation run off the main actor on a dedicated queue;
only the results cross back.
