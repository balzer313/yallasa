<div align="center">
  <img src="yallasa-logo.jpg" alt="יאללה סע" width="180">
  <h1>יאללה סע · Yalla Sa</h1>
  <p><strong>ללא פרסומות · no ads, no account, no server</strong></p>
</div>

A transit app for iPhone that runs the whole thing on the phone.

Download a city's public timetable once. From then on the app compiles it,
indexes it, plans journeys across it and shows live departure boards from it —
with no backend, no API key, and no cloud bill. Turn on airplane mode and
everything except live delays still works.

```
┌─────────────┐   HTTPS    ┌──────────────┐   on device   ┌───────────────┐
│ Agency GTFS │ ─────────▶ │  .zip → CSV  │ ────────────▶ │  .mvtg graph  │
│   (free)    │            │   importer   │               │ memory-mapped │
└─────────────┘            └──────────────┘               └───────┬───────┘
                                                                  │
                        ┌─────────────────────────────────────────┤
                        ▼                                         ▼
                 RAPTOR planner                           departure boards
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
| [`docs/SHIPPING.md`](docs/SHIPPING.md) | how a build gets from Windows to TestFlight |

## Layout

```
Sources/YallaSaKit/    the engine — pure Swift, no UI, testable on macOS
  Core/                indices, coordinates, service dates, modes
  IO/                  ZIP reader, CSV reader
  GTFS/                the importer: GTFS archive → compiled graph
  Graph/               the on-disk format, its writer, and the mmap reader
  Routing/             RAPTOR, range-RAPTOR, journey reconstruction, boards
  Realtime/            protobuf reader, GTFS-RT decode, delay overlay
  Feeds/               catalog, download, atomic versioned install
  Search/              stop name index
  TransitService.swift the single door between engine and UI

Sources/YallaSa/       the iOS app — SwiftUI
  App/                 entry point, tab shell, routing, first-run feed gate
  DesignSystem/        tokens, formatters, shared components
  Presentation/        Presenter + plain ViewData structs
  Features/            Nearby, Planner, Journey, Lines, StopDetail, Map, Settings
  Services/            location, saved places, favourites

Resources/
  Localizable.xcstrings   UI strings — English source, Hebrew translations
  InfoPlist.xcstrings     app name and permission prompts, both languages
  PrivacyInfo.xcprivacy   required-reason API declarations

Tests/YallaSaKitTests/ engine tests, runnable with `swift test` on macOS
```

## Language

The app is Hebrew-first with RTL layout, and falls back to English on any other
locale. English is the *source* language — the literals in the Swift files are
English and `Resources/Localizable.xcstrings` carries the Hebrew. That ordering
is deliberate: it keeps the code readable to a non-Hebrew reader and keeps the
translations in one reviewable file instead of scattered through the views.

## Building

**This repository is authored on Windows. Building it requires macOS.**
The engine is a plain Swift package and its tests run anywhere Swift runs; the
app target needs Xcode.

You do not need to *own* a Mac. Both workflows in `.github/workflows/` run on
GitHub's macOS runners:

| Workflow | What it does | Needs signing? |
|---|---|---|
| `ci.yml` | builds the engine, runs the tests, builds the app for the simulator | no |
| `release.yml` | archives, signs, and uploads a build to TestFlight | yes — four secrets |

`release.yml` uses `-allowProvisioningUpdates` with an App Store Connect API
key, so Xcode creates the certificate and the provisioning profile on the runner
itself. See [`docs/SHIPPING.md`](docs/SHIPPING.md) for the one-time setup.

Locally, on a Mac:

```bash
swift build && swift test        # engine only, no Xcode needed
brew install xcodegen
xcodegen generate                # produces YallaSa.xcodeproj from project.yml
open YallaSa.xcodeproj
```

The Xcode project is generated rather than committed: a hand-maintained
`.pbxproj` is a merge-conflict machine, and it could not be produced honestly on
the machine this was written on.

Requirements: iOS 17+, Xcode 15+, Swift 5.9.

## Feeds

**Israel only.** The catalog (`Sources/YallaSaKit/Feeds/FeedCatalog.swift`)
carries the Ministry of Transport's national archive and three metro clips of
it. It used to also list eight New York feeds, from when this was a generic
GTFS reader — no rider of a Hebrew transit app was ever going to install the
Staten Island bus network.

**A first run installs the whole country automatically**, with no picker. There
is exactly one right answer for this audience, and a screen whose only job is to
be dismissed should not exist. Unclipped, too: clipping to a metro box made the
app quietly wrong the moment a rider left it — an intercity bus to Eilat simply
did not exist.

Two things still worth knowing:

- **It is a big first run.** ~133 MB zipped, about a gigabyte expanded. That is
  survivable now only because large tables inflate through a mapped file rather
  than the heap; see the fix below.
- **URLs rot.** Agencies move their endpoints without notice. The catalog is
  best-effort, and `FeedSource.custom(staticURL:name:)` — any GTFS zip URL
  pasted in Settings — is the real answer, including for feeds outside Israel.

## Dependencies

None. Foundation, Compression, SwiftUI, MapKit and CoreLocation only. The ZIP
reader, the CSV parser and the protobuf decoder are all in-tree — about 900 lines
that replace three third-party packages, keep the binary small, and remove a
supply chain from an app whose whole premise is that it does not phone home.

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
macOS runner is what turned "written" into "known to compile".

**The feed endpoint is live, and so are the buses.** Verified 2026-08-21: the
MOT archive returns 139,433,456 bytes with a valid `ETag` and a `Last-Modified`
one day old, and it is ZIP64 — `routes.txt` was pulled out of it by HTTP range
request and inflated to exactly its declared 956,158 bytes.

Live positions were checked end to end against the real API: **107 vehicles, 77
lines, 65 moving, freshest fix 80 seconds old** — and **75 of 75 sampled SIRI
`line_ref` values matched a GTFS `route_id`** in the real 7,605-route feed,
which is the join the whole live map depends on.
`.github/workflows/live-israel.yml` re-runs that check every Monday morning.

Still unverified, and worth being clear about:

- **The app has never been launched.** Compiling is not running. Everything
  past the first launch is unknown until a build reaches a phone.
- **No real feed has been imported end to end.** The endpoints are confirmed
  reachable and correctly shaped; nothing has parsed one all the way through.
- **No performance number here has been measured.** Every figure in `GOAL.md`
  and `docs/ALGORITHM.md` is a design target, labelled as one.

### Fixed: large entries no longer inflate whole

`ZipArchive` used to allocate an entry's full uncompressed size in a single
buffer. Israel's `stop_times.txt` is **520 MB** uncompressed and `shapes.txt`
is 219 MB, against a 250 MB budget — asking iOS for that on first run is a
jetsam kill the app cannot even report, because the process is gone.

Entries over 32 MB now inflate to a temporary file in 4 MB chunks and are
memory-mapped. The kernel pages them, so resident memory stays flat regardless
of entry size, and `CSVReader` still receives the contiguous buffer it always
expected — not one line of parsing changed.

`docs/REVIEW.md` records what the review and the first nine CI rounds found —
including a critical ZIP bug that would have broken every feed import, a
`GeoBounds` encoding bug that would have broken every feed *install*, and a CI
step that reported success over a failed build.

The router tests are the ones to trust first: they build a real graph through the
actual binary writer and assert hand-computed arrival times, including the
after-midnight case that quietly breaks most hand-rolled transit routers.
