# Goal — Move It

## The goal

**Ship an iPhone transit app that answers "when is my bus, and how do I get there?" entirely on the device — no server, no backend bill, no API key.**

Everything Moovit does with a datacenter, Move It does with the phone's own CPU:
the app downloads a public GTFS feed once, compiles it into a compact binary
transit graph on-device, and runs a RAPTOR journey planner locally against that
graph. The only network traffic is (a) fetching the feed, and (b) optionally
polling a public GTFS-Realtime endpoint for delays.

## Success criteria

The goal is met when, on an iPhone 12 or newer, with the device in airplane mode
after the initial feed download:

| # | Criterion | Target |
|---|---|---|
| 1 | Nearby departures board opens and shows live countdowns | < 400 ms cold, < 100 ms warm |
| 2 | Door-to-door journey plan across a metro-sized feed | < 300 ms p50, < 1 s p95 |
| 3 | Feed compile (GTFS zip → queryable graph), 2M stop_times | < 90 s, ≤ 250 MB peak RAM |
| 4 | Compiled graph on disk | ≤ 1.5× the zipped GTFS size |
| 5 | Journey correctness vs. reference planner | ≥ 99% identical arrival times |
| 6 | Works fully offline once a feed is installed | 100% of features except realtime |
| 7 | Recurring cloud cost | **$0.00** |

## Non-goals (deliberately out of scope for v1)

- Turn-by-turn street routing. Walking legs are straight-line distance with a
  configurable detour factor — good enough for "walk 4 min to the stop", and it
  keeps us off paid routing APIs.
- Multi-region search. One feed is active at a time; switching regions is explicit.
- Accounts, sync, social, ads, trip history upload. There is no server to sync to.
- Ride-hailing / micromobility / ticketing integrations.

## Constraints that shaped every design decision

1. **No cloud compute.** Rules out server-side graph building, server-side
   routing, and any hosted planner API (OTP, Google Directions, Transitland routing).
2. **No API key.** Rules out most "transit APIs". GTFS static + GTFS-Realtime are
   plain file downloads over HTTPS, which is why the whole design is built on them.
3. **Phone-sized budget.** ~200 MB RAM ceiling and a battery. This is why the graph
   is a memory-mapped columnar file rather than an object graph, and why the router
   is RAPTOR (array scans, no priority queue, cache-friendly) rather than Dijkstra
   on a time-expanded graph.
4. **No third-party Swift packages.** ZIP reading, CSV parsing and protobuf decoding
   are all implemented in-tree against Apple frameworks only. Fewer supply-chain
   surprises, smaller binary, no version drift.

## What "production level" means here

- Every engine module has unit tests; the router has correctness tests against
  hand-built fixture feeds with known-good answers.
- Feed installs are atomic and versioned — a failed or interrupted compile can
  never leave the app with a half-written graph.
- Full VoiceOver labelling, Dynamic Type, and reduced-motion support.
- No force-unwraps on parsed feed data. Real feeds are dirty; the importer is
  written to survive them and report what it dropped.
- Documented, reviewed, and shipped with a build guide that a Mac can follow.
