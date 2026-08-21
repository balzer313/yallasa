# Architecture

## The one-sentence version

The phone downloads a public GTFS archive, compiles it into a memory-mapped
columnar file, and runs a RAPTOR journey planner over that file — so the app has
no backend, and the only thing the network is ever used for is fetching data
files.

## Why on-device at all

The obvious way to build this is a server: ingest GTFS, run OpenTripPlanner,
expose `/plan`. That is what almost every transit app does, and it costs money
forever, needs an ops story, and stops working on the Tube.

The observation that makes the server unnecessary is that a *metro-sized*
timetable is small. A city's worth of GTFS is on the order of a few million
stop-times. At 8 bytes each that is tens of megabytes — less than a podcast
episode. The routing algorithm that operates on it, RAPTOR, is a handful of
array scans. An iPhone from 2020 does this in tens of milliseconds. The
datacenter was never doing anything the phone could not.

What the phone genuinely cannot do is *street* routing, which needs an OSM
extract an order of magnitude larger than the timetable. So the app does not do
street routing: walking legs are straight-line distance times a detour factor.
For "walk 4 minutes to the stop" this is indistinguishable from the truth, and it
is the one deliberate accuracy trade-off in the design.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI                                                       │
│   Views ─ ViewData ─ Presenter ─ feature view models           │
├──────────────────────────────────────────────────────────────┤
│ TransitService                    (the only door in the wall)  │
├──────────────────────────────────────────────────────────────┤
│ YallaSaKit                                                      │
│   Feeds   ─ catalog, download, atomic install, manifest        │
│   GTFS    ─ importer: CSV → patterns → columns → .mvtg         │
│   Graph   ─ TransitGraph (mmap reader), writer, format         │
│   Routing ─ RAPTOR, range-RAPTOR, journey reconstruction       │
│   Realtime─ protobuf reader, GTFS-RT decode, delay overlay     │
│   Search  ─ stop name index                                    │
│   IO      ─ ZIP reader, CSV reader                             │
└──────────────────────────────────────────────────────────────┘
```

Dependencies point strictly downward. `Routing` knows about `Graph` and
`Realtime`; `Graph` knows about nothing but `Core`. The UI knows about
`TransitService` and the plain data structs it vends, and nothing else — a view
cannot reach a `TransitGraph` even if it wants to.

## The graph file is the whole design

Everything else follows from one decision: the compiled timetable is a flat,
little-endian, structure-of-arrays binary file that is `mmap`ed rather than
parsed.

**Structure of arrays, not objects.** RAPTOR's inner loop reads arrival times and
almost nothing else. In an object graph, each `StopTime` would drag its trip
pointer, stop pointer and flags into cache alongside the one `Int32` the loop
wants. As columns, the router walks contiguous `Int32`s and every cache line it
pulls in is 16 useful values.

**Memory-mapped, not loaded.** A 250 MB graph costs approximately zero resident
memory until a query touches it, and the pages it does touch are clean file-backed
pages the kernel can evict under pressure instead of jettisoning the app. Opening
a feed is an `mmap` syscall, not a parse — the app is usable the instant it
launches, which is the difference between a transit app and a chore.

**Dense integer indices, not string ids.** Stops, routes, trips and services are
`Int32` indices into columns. GTFS string ids survive only in a side table, used
for two things: matching realtime updates, and persisting favourites across a
feed rebuild.

**CSR adjacency.** Stop→patterns and stop→transfers are compressed sparse row:
a start offset and a count per stop, indexing into one flat payload array. No
per-stop array allocation, no pointer chasing.

The trade is that the format is rigid — adding a column means bumping
`GraphFormat.version`, and the app responds by recompiling from the cached
archive. That is the right trade for something rebuilt from source data on the
device that reads it.

## Data pipeline

```
 GTFS .zip ──▶ ZipArchive ──▶ CSVReader ──▶ intermediate tables
                                                  │
                       ┌──────────────────────────┤
                       ▼                          ▼
              ServiceCalendarBuilder        PatternBuilder
              (weekday masks + exceptions   (group trips by identical
               → one bitset per service)     stop sequence, split on
                       │                     overtaking, sort by time)
                       │                          │
                       └────────────┬─────────────┘
                                    ▼
                            TransferBuilder
                (transfers.txt + proximity footpaths + bounded
                 Dijkstra closure, capped out-degree)
                                    ▼
                          TransitGraphWriter ──▶ .mvtg
```

Three things in there are load-bearing and easy to get wrong:

**Patterns.** RAPTOR's notion of a "route" is not a GTFS route — it is a maximal
set of trips sharing an identical ordered stop sequence. The 42 bus that
short-turns halfway is two patterns, not one. Getting this grouping right is what
makes the scan-a-route-once structure of the algorithm valid.

**The overtaking split.** RAPTOR binary-searches a pattern's trips by departure
time, which assumes that sorting by departure at the first stop also sorts them
at every other stop. Real feeds violate this — an express overtakes a local on a
shared pattern. The importer detects this and splits the offenders into their own
pattern. Skipping this check does not make the router slow; it makes it silently
return journeys you cannot actually catch.

**Transitively closed footpaths.** RAPTOR assumes that if you can walk A→B and
B→C, the transfer list for A already contains C. The importer computes a bounded
Dijkstra closure to guarantee it. Without closure the router misses journeys
rather than producing wrong ones, which is harder to notice and just as bad.

## Time

Every time in the engine is `ServiceSeconds` — seconds since midnight of a named
service date, in the feed's timezone — and never a bare `Date`.

This is not fussiness. GTFS service days are civil dates, a day across a DST
boundary is 23 or 25 hours long, and GTFS times legally exceed 24:00:00 to
express "the 00:35 bus is still Saturday's service". Doing this arithmetic in
`Date` and `TimeInterval` produces a planner that is wrong twice a year and wrong
every night after midnight. `ServiceDate` uses Howard Hinnant's civil-date
algorithms, which are exact and timezone-free; conversion to a wall-clock
`Date` happens once, at the display boundary, in `Format`.

## Realtime

GTFS-Realtime is protobuf over HTTPS. Rather than take a dependency on
SwiftProtobuf for four message types, the engine has a ~200-line wire-format
reader that decodes the fields it uses and skips everything else by wire type —
which is also what makes it robust, since agencies add fields without notice.

A decoded feed is resolved *once* against the graph into a `RealtimeIndex` keyed
by `TripIndex`. The router's hot loop therefore never touches a string or hashes
one; it does an integer lookup. Snapshots are immutable, so a query holds one for
its whole duration and a mid-query refresh cannot tear it.

Realtime changes results but never blocks them: with no network, or with a feed
that has no realtime endpoint, everything still works on the timetable and the UI
says so — `LiveStatus.scheduled` renders differently from `LiveStatus.onTime`,
because "we don't know" and "it's on time" are different claims.

## Concurrency

- `TransitService` is `@MainActor` and publishes to SwiftUI.
- Every query runs on a private concurrent queue; only results cross back.
- `TransitGraph` is immutable after open and safe to share; `JourneyPlanner`
  holds no mutable state, so two searches can run at once against one graph.
- All RAPTOR scratch state lives in a per-query `RaptorContext`.
- `FeedManager` is an `actor`, because install/activate/remove genuinely need
  serialising against each other.

## Failure model

The app's worst realistic failure is not a crash — it is confidently telling
someone about a bus that does not exist. So:

- An expired feed is detected (`GraphMetadata.covers(_:)`) and surfaced loudly,
  rather than silently returning "no journeys found".
- Feed installs are atomic: download to temp, compile to temp, `replaceItem` into
  place. A crash mid-install leaves the previous graph or none, never a partial one.
- Graph sections are bounds- and alignment-validated at open, so a truncated file
  throws at open rather than reading garbage during a query.
- The importer never force-unwraps feed data; malformed rows are dropped and
  counted in `GraphMetadata.ImportReport`, which Settings shows to the rider.
- The router has a wall-clock budget and returns best-so-far on expiry.
