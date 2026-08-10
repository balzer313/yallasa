# Data sources

Everything the app consumes is a public file over HTTPS. There is no "transit
API" in the product, because every transit API worth using wants a key, a quota
and a terms-of-service relationship — and this app is built on the premise that
it never needs an account with anybody.

## The two formats

**GTFS (static)** is a ZIP of CSV files describing a timetable: stops, routes,
trips, stop times, and a calendar of which services run on which days. It is the
universal interchange format for published transit schedules, it is what almost
every agency on earth publishes, and it requires no authentication because it is
just a file on a web server.

**GTFS-Realtime** is a protobuf document describing deviations from that
timetable: delays, cancellations, skipped stops, service alerts. Some agencies
gate it behind a key; a useful number do not.

## Verified endpoints

Probed live on 2026-08-09. All returned HTTP 200 with a valid payload, and all
are HTTPS with no API key and no registration.

### New York — MTA

The legacy `http://web.mta.info/developers/data/...` paths still work and are
still what most documentation points at, but the *same files* are served over
HTTPS from S3. The catalog uses the HTTPS ones, which is why the app ships with
no App Transport Security exception.

| Feed | URL | Size |
|---|---|---|
| Subway | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip` | 5.6 MB |
| Subway + planned changes | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_supplemented.zip` | 19.5 MB |
| Bus — Manhattan | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_m.zip` | 6.7 MB |
| Bus — Brooklyn | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_b.zip` | 13.5 MB |
| Bus — Bronx | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_bx.zip` | 6.8 MB |
| Bus — Queens | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_q.zip` | 4.7 MB |
| Bus — Staten Island | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_si.zip` | 5.0 MB |
| Bus — MTA Bus Company | `https://rrgtfsfeeds.s3.amazonaws.com/gtfs_busco.zip` | 5.6 MB |
| Long Island Rail Road | `https://rrgtfsfeeds.s3.amazonaws.com/gtfslirr.zip` | 1.8 MB |
| Metro-North | `https://rrgtfsfeeds.s3.amazonaws.com/gtfsmnr.zip` | 3.7 MB |

> The commuter rail keys have **no underscore** — `gtfslirr.zip`, `gtfsmnr.zip`.
> `gtfs_lirr.zip` and `gtfs_mnr.zip` both return 403. Nothing about the naming
> tells you this; it just is.

Realtime, also key-free:

| Feed | URL | Notes |
|---|---|---|
| Subway trip updates | `https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs` | 53 KB, protobuf, **served as `text/plain`** — do not gate decoding on content type |
| Service alerts (all modes) | `https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fall-alerts` | 663 KB, `application/x-protobuf` |

### Israel — Ministry of Transport

`https://gtfs.mot.gov.il/gtfsfiles/israel-public-transportation.zip` — **141 MB**
compressed, roughly 4,200 routes and 30,500 stops across 36 agencies, nationwide.
Files sit at the archive root (first entry is `agency.txt`, no nested folder).

This is the case the region-clipping feature exists for. Importing the whole
country onto a phone is possible but wasteful; the catalog exposes it as several
sources sharing one URL with different metro bounding boxes, so a rider in Tel
Aviv compiles Tel Aviv.

The MOT publishes realtime as **SIRI**, not GTFS-Realtime, and it requires a key.
The Israel sources therefore carry no realtime URL, and the app falls back to
timetable-only — which it is designed to do gracefully.

## A trap worth knowing about

`gtfs.mot.gov.il` answers `HEAD` with **HTTP 200 and `Content-Length: 3382`**,
while the `GET` for the same URL returns 148,010,505 bytes.

This breaks two things if you trust it:

1. **Progress reporting.** A download bar sized from HEAD reaches 100% after
   3 KB and then keeps going for another 141 MB. `FeedDownloader` takes its
   expected total from the GET response and falls back to indeterminate progress
   when the value is missing or implausible.
2. **Change detection.** `refreshIfNeeded` must not compare HEAD `Content-Length`
   to decide whether a feed changed, or this host will look unchanged forever.
   Only `ETag` and `Last-Modified` are trusted; absent those, the app falls back
   to a time-based refresh.

The general lesson, which applies to transit data far beyond this one host: these
are files published by transport authorities, not products with SLAs. Assume
every server is a little bit broken and degrade rather than trust.

## Finding more feeds

- **Mobility Database** (`mobilitydatabase.org`) — the successor to the
  TransitFeeds registry; the most complete catalog of GTFS sources.
- **Transitland** (`transit.land`) — feed registry plus archived historical
  versions.
- Most agencies have an "open data" or "developers" page with a direct link.

Anything that resolves to a plain HTTPS `.zip` works in the app's custom-URL
field. Feed URLs rot constantly, which is why the bundled catalog is deliberately
short and verified rather than long and hopeful.

## Licensing

Transit feeds carry licences, and several agencies require visible attribution as
a condition of use. `FeedSource` carries `attribution` and `licenseURL`, Settings
displays both, and that is a legal requirement rather than a courtesy. Check the
terms before adding a feed to the bundled catalog — "publicly downloadable" is
not the same as "licensed for redistribution in your app".
