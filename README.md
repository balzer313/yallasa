# Move It

A transit app for iPhone that runs the whole thing on the phone.

Download a city's public timetable once. From then on the app compiles it,
indexes it, plans journeys across it and shows live departure boards from it —
with no backend, no API key, and no cloud bill. Turn on airplane mode and
everything except live delays still works.

```
┌─────────────┐   HTTPS    ┌──────────────┐   on device   ┌──────────────┐
│ Agency GTFS │ ─────────▶ │  .zip → CSV  │ ────────────▶ │ .mvtg graph  │
│  (free)     │            │   importer   │               │  memory-mapped│
└─────────────┘            └──────────────┘               └──────┬───────┘
                                                                 │
                        ┌────────────────────────────────────────┤
                        ▼                                        ▼
                 RAPTOR planner                          departure boards
```

## Where to start reading

| | |
|---|---|
| [`GOAL.md`](GOAL.md) | what this is for, and the numbers that define "done" |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | how it is put together and why on-device is viable |
| [`docs/ALGORITHM.md`](docs/ALGORITHM.md) | the RAPTOR planner, in detail |
| [`docs/CONTRACTS.md`](docs/CONTRACTS.md) | normative engine module APIs |
| [`docs/APP-CONTRACTS.md`](docs/APP-CONTRACTS.md) | normative SwiftUI layer APIs |
| [`docs/REVIEW.md`](docs/REVIEW.md) | the review pass: findings and fixes |

## Layout

```
Sources/MoveItKit/     the engine — pure Swift, no UI, testable on macOS
  Core/                indices, coordinates, service dates, modes
  IO/                  ZIP reader, CSV reader
  GTFS/                the importer: GTFS archive → compiled graph
  Graph/               the on-disk format, its writer, and the mmap reader
  Routing/             RAPTOR, range-RAPTOR, journey reconstruction, boards
  Realtime/            protobuf reader, GTFS-RT decode, delay overlay
  Feeds/               catalog, download, atomic versioned install
  Search/              stop name index
  TransitService.swift the single door between engine and UI

Sources/MoveIt/        the iOS app — SwiftUI
  App/                 entry point, tab shell, routing, first-run feed gate
  DesignSystem/        tokens, formatters, shared components
  Presentation/        Presenter + plain ViewData structs
  Features/            Nearby, Planner, Journey, Lines, StopDetail, Map, Settings
  Services/            location, saved places, favourites

Tests/MoveItKitTests/  engine tests, runnable with `swift test` on macOS
```

## Building

**This repository was authored on Windows. Building it requires a Mac.**
The engine is a plain Swift package and its tests run anywhere Swift runs; the
app target needs Xcode.

```bash
# 1. Engine only — no Xcode needed, works on macOS with a Swift toolchain
swift build
swift test

# 2. The app
brew install xcodegen
xcodegen generate          # produces MoveIt.xcodeproj from project.yml
open MoveIt.xcodeproj
```

The Xcode project is generated rather than committed: a hand-maintained
`.pbxproj` is a merge-conflict machine, and it could not be produced honestly on
the machine this was written on.

Requirements: iOS 17+, Xcode 15+, Swift 5.9.

## Adding a city

The bundled catalog (`Sources/MoveItKit/Feeds/FeedCatalog.swift`) holds transit
feeds that need no API key and no registration. Riders can also paste any GTFS
URL in Settings.

Two things to know about feeds:

- **National feeds are huge.** Israel's national GTFS is ~1 GB unzipped. The app
  handles this by letting you clip a feed to a metro-area bounding box at import
  time, which is what makes a national feed usable on a phone.
- **URLs rot.** Agencies move their endpoints without notice. The catalog is
  best-effort; the custom-URL path is the real answer.

## Dependencies

None. Foundation, Compression, SwiftUI, MapKit and CoreLocation only. The ZIP
reader, the CSV parser and the protobuf decoder are all in-tree — about 900 lines
that replace three third-party packages, keep the binary small, and remove a
supply chain from a app whose whole premise is that it does not phone home.

## Licence and attribution

The code is yours. The *data* is not: transit feeds carry their own licences and
several agencies require visible attribution. `FeedSource` carries an
`attribution` string and a `licenseURL` for exactly this reason, and Settings
displays both. If you ship this, honour them.

## Status

**Builds and passes its tests**, verified on GitHub Actions macOS runners:

```
Executed 200 tests, with 0 failures (0 unexpected) in 0.405 seconds
** BUILD SUCCEEDED **          (iOS app, simulator, Xcode 16)
```

The project was authored on Windows, where the iOS SDK does not exist, so CI on a
macOS runner is what turned "written" into "known to compile". `.github/workflows/ci.yml`
runs it on every push — you do not need a Mac to keep this honest.

Still unverified, and worth being clear about:

- **No performance number here has been measured.** Every figure in `GOAL.md` and
  `docs/ALGORITHM.md` is a design target, labelled as one.
- **No real feed has been imported.** The endpoints in `docs/DATA-SOURCES.md` are
  verified reachable and correctly sized; nothing has parsed one end to end.
- **The app has never been launched.** Compiling is not running. See
  `docs/BUILDING-WITHOUT-A-MAC.md` for how to get it onto a phone.

`docs/REVIEW.md` records what the review and the first nine CI rounds found —
including a critical ZIP bug that would have broken every feed import, a
`GeoBounds` encoding bug that would have broken every feed *install*, and a CI
step that reported success over a failed build.

The router tests are the ones to trust first: they build a real graph through the
actual binary writer and assert hand-computed arrival times, including the
after-midnight case that quietly breaks most hand-rolled transit routers.
