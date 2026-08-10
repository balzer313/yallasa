# Review

Findings from the review pass, and — just as important — an honest statement of
what could not be checked.

## The caveat that governs everything below

**This code has never been compiled.** It was authored on a Windows machine with
no Swift toolchain. Every review finding here comes from reading, not from a
compiler, a test run, or a profiler.

That means:

- **Type and syntax errors are likely to remain.** The seam audit checked call
  sites against pinned signatures by hand, which catches structural mismatches
  but will not catch every `Int` vs `Int32` conversion Swift demands explicitly.
- **No performance number in `GOAL.md` or `ALGORITHM.md` has been measured.**
  They are design targets derived from the algorithm's complexity and from
  published RAPTOR results — they are not observations, and they are labelled as
  targets everywhere they appear.
- **No test has been run.** The test suites are written and are meant to be the
  first thing executed on a Mac.

Treat the first `swift build && swift test` as a real work item.

## State of the code

The engine and the app are both structurally complete: every module named in
`CONTRACTS.md` and every screen named in `APP-CONTRACTS.md` exists, and the
navigation graph closes — there is no view referenced by the shell that is not
written.

Test coverage is complete across the engine: IO (CSV, ZIP), realtime (protobuf,
decoder, index), the calendar/pattern/transfer builders, the GTFS importer
end-to-end, the router, the departure boards, the feed catalog, manifest and
manager, and app-layer formatting.

Two pieces of the engine were written by hand after the agent that owned them was
terminated mid-run by an account usage limit — `JourneyPlanner` and
`DepartureBoardService`, built against the `RaptorContext` / `ForwardRaptor` /
`BackwardRaptor` / `JourneyBuilder` internals it had already completed. They are
flagged here because they are the newest code in the engine and the parts whose
first compile is most likely to need attention.

### How the tests are built

Two decisions in `Tests/MoveItKitTests/Support/` are worth knowing before
changing anything there:

**`GraphFixture` is not a mock.** It writes the real binary format through
`TransitGraphWriter` and reads it back through `TransitGraph`. A router test that
passes therefore proves the router and the reader agree on addressing — which is
exactly the class of bug (an off-by-one in `patternStopTimeStart`, a CSR range
pointing at the wrong stop) that a mocked graph would hide by construction.

**`ZipBuilder` computes its own CRC-32** rather than calling the engine's
`ZipCRC32`. Generating and verifying with the same code would cancel out a fault
in the table. It also writes a deliberately non-empty *local* extra field while
leaving the central one empty, so an importer that computes the payload offset
from the central record lands in the middle of the data and fails loudly.

The router tests carry their expected times as hand-computed constants derived
from the fixture timetable, not values captured from a run. A router that agrees
with itself proves nothing.

## Findings

Severity: **critical** = would fail at runtime for most users; **major** =
wrong results or a broken feature in a common case; **minor** = correctness or
robustness nit.

### 1. `ZipArchive.inflate` rejected every deflated entry — **critical**, fixed

`Sources/MoveItKit/IO/ZipArchive.swift`

The output buffer was allocated at exactly the entry's declared uncompressed
size, and the loop treated `COMPRESSION_STATUS_OK` with a full destination as
"this entry inflates to more than it declared" and threw.

With an exactly-sized destination the decoder writes the final byte, finds no
room left, and returns `OK` — it has not yet consumed the end-of-stream marker.
`END` only arrives on a call that has output space available. Since the buffer is
*always* exactly sized, this path would be reached for essentially every
compressed entry, so **every GTFS import would have failed** with a spurious
"inflates to more than the declared N bytes".

Fixed by allocating one byte of slack beyond the declared size. The decoder can
then always reach the end marker in the same call that emits the last byte, so
`END` unambiguously means "matched the declared size" and a full buffer
unambiguously means the header lied. The final `produced == expectedSize` check
still catches a truncated stream.

The same edit replaced an `UnsafeMutablePointer.allocate` + `.pointee` read of
uninitialised memory with a direct `compression_stream(...)` memberwise
construction. The original is Apple's own sample idiom and would have worked in
practice, but it is undefined behaviour by the letter and there is no reason to
keep it.

### 2. Feed catalog was going to ship unverified and partly-dead URLs — **major**, fixed

Endpoints were probed live rather than recalled. Three corrections:

- Every MTA feed is served over **HTTPS** from `rrgtfsfeeds.s3.amazonaws.com`,
  not only over the widely-documented legacy `http://web.mta.info` paths. The
  catalog now uses HTTPS and **the App Transport Security exception was removed
  from `Info.plist` entirely** — the app ships with no transport-security holes.
- LIRR and Metro-North are `gtfslirr.zip` / `gtfsmnr.zip`, with **no
  underscore**, unlike every other MTA feed. The underscored spellings 403.
- Both MTA GTFS-Realtime endpoints work with no API key. The trip-updates feed
  is served as `Content-Type: text/plain` despite being protobuf, so decoding
  must not be gated on content type.

### 3. `gtfs.mot.gov.il` returns a false `Content-Length` on HEAD — **major**

A `HEAD` on the Israel national feed returns **HTTP 200 with
`Content-Length: 3382`**. The `GET` returns **148,010,505 bytes**.

Two consequences, both handled in `FeedDownloader`/`FeedManager`:

1. A progress bar sized from HEAD reaches 100% after 3 KB and then runs for
   another 141 MB. Expected totals are taken from the GET response, and
   implausible or absent values fall back to indeterminate progress.
2. A `refreshIfNeeded` that compares HEAD `Content-Length` would consider this
   feed unchanged forever. Only `ETag`/`Last-Modified` are trusted; absent those,
   the app falls back to a time-based refresh.

The general lesson, recorded in `docs/DATA-SOURCES.md`: these are files published
by transport authorities, not products with SLAs. Degrade, never trust.

### 4. Extended GTFS route types were mapped with overlapping patterns — **major**, fixed

`Sources/MoveItKit/Core/RouteType.swift`

The first draft of `TransitMode(gtfsRouteType:)` had overlapping `case` patterns
(`405` in both the monorail and urban-railway arms, `1500...1507` overlapping the
funicular and ferry arms) and an invalid `where false` clause that would not have
compiled. Rewritten so specific codes precede the ranges that contain them, which
is what Swift's first-match-wins semantics requires.

### 5. `TransitService.bootstrap()` had a `guard` that could fall through — **major**, fixed

A `guard ... else { }` whose body did not exit scope. Replaced with an explicit
`switch` over `TransitServiceState`.

### 6. `Color(uiColor:)` without `UIKit` in scope — **minor**, fixed

`DesignSystem/Theme.swift` relied on SwiftUI transitively importing UIKit.
Added an explicit `#if canImport(UIKit)` import.

## Deliberate deviations from the contracts

Recorded so they are decisions rather than drift.

- **`CSVReader.next()` skips wholly blank lines** instead of returning a
  one-empty-field row. Feeds terminate with anywhere from zero to three trailing
  newlines and a phantom row per table is a bug magnet. Two tests pin this.
- **`ZipArchive.init` can throw `GraphError`**, not only `ZipError`, because it
  reuses `GraphMemory.map` rather than carrying a second mmap implementation.
  Callers must catch `Error` generally when wrapping archive failures.
- **`ZipArchive` sizes its inflate buffer from the central directory** rather
  than growing dynamically. The directory's size field is authoritative even for
  entries written with a trailing data descriptor, and it turns a lying header
  into a thrown error instead of an unbounded allocation driven by the archive.

## What a compiler and a device still have to check

1. `swift build` and `swift test` for `MoveItKit`, then `xcodegen generate` and a
   device build of the app.
2. **A real feed end to end.** Compile NYC subway (5.6 MB — the fast loop) and
   then the Israel national feed clipped to Tel Aviv (141 MB — the stress case).
   Watch peak RSS against the 250 MB budget.
3. **Router correctness against a reference.** The fixture tests assert exact
   arrival times on hand-built graphs, which catches structural errors, and they
   cover the after-midnight case, inactive services, arrive-by, transfer limits,
   walking budgets and realtime disruption. They do *not* prove agreement with a
   mature planner on a real network; a spot-check against OpenTripPlanner on a
   few hundred origin/destination pairs is the honest way to earn the "≥99%
   identical arrival times" line in `GOAL.md`.
4. **Overtaking splits on a real feed.** `GTFSImporterTests` proves the split
   happens on a synthetic express, and asserts the invariant the router depends
   on — departures non-decreasing at *every* position of *every* pattern. Run
   that same assertion over a compiled real feed; it is cheap and it silently
   breaks the router when violated.
5. **Memory behaviour under pressure**, with the graph mapped and the app
   backgrounded — the scenario `mmap` was chosen for, and therefore the one worth
   verifying rather than assuming.
6. **The `install` progress monotonicity assertion** in `FeedManagerTests`
   encodes a requirement rather than an observation: progress must never go
   backwards. If it fails, fix the reporting rather than the test.
