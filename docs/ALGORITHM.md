# The journey planner

## Why RAPTOR

The textbook approach to timetable routing is Dijkstra over a time-expanded
graph: one node per (stop, time) event, one edge per connection. It is correct
and it is a bad fit for a phone. The graph has tens of millions of nodes, the
priority queue thrashes cache, and every query allocates.

RAPTOR (Delling, Pajor, Werneck — *Round-Based Public Transit Optimized Router*)
throws the queue away. It observes that a journey with *k* transfers is found by
*k+1* rounds of "scan every route reachable from what I already know". Each round
is a linear pass over arrays. There is no priority queue, no heap, no pointer
chasing, and the memory access pattern is sequential — which is precisely what a
phone's cache hierarchy and battery want.

It also solves the multi-criteria problem for free. Riders do not just want the
earliest arrival; they want the trade-off between arriving early and not changing
buses three times. RAPTOR's round structure *is* the transfer dimension: the label
after round *k* is the earliest arrival using at most *k* transfers, so the Pareto
set falls out of the algorithm rather than being bolted on.

## The core loop

State per round *k*:

- `arrival[k][stop]` — earliest known arrival at `stop` using ≤ *k* transfers.
- `best[stop]` — earliest arrival over all rounds so far, used for pruning.
- `marked` — stops whose label improved in round *k−1*.

```
round 0:  walk from the origin to every stop within the access radius
          mark those stops

for k in 1 ... maxTransfers+1:

    # 1. build the route queue
    for each marked stop s:
        for each (pattern p, position i) serving s:
            queue[p] = min(queue[p] ?? i, i)      # earliest boarding point
    clear marked

    # 2. scan each pattern once, forward
    for each (p, startPosition) in queue:
        trip = none
        for i in startPosition ..< p.stopCount:
            s = p.stop(i)

            if trip exists and p.allowsAlighting(i):
                t = arrivalTime(p, trip, i)        # + realtime delay
                if t < min(best[s], best[target]):  # target pruning
                    arrival[k][s] = t; best[s] = t; mark s

            # can we catch an earlier trip by boarding here?
            if p.allowsBoarding(i) and arrival[k-1][s] + slack <= departureTime(p, trip, i):
                trip = earliestTrip(p, i, after: arrival[k-1][s] + slack)

    # 3. relax footpaths from every stop marked in step 2
    for each marked stop s, for each transfer (s → t, seconds):
        if best[s] + seconds < best[t]:
            arrival[k][t] = best[s] + seconds; mark t

    if nothing marked: stop
```

Two details in there matter more than they look.

**Target pruning.** Comparing against `best[target]` as well as `best[s]` cuts a
large fraction of the work: once you know you can reach the destination by 09:40,
any label later than that can never lead to an improvement, so it is not worth
propagating. On a metro feed this is worth several times over.

**One trip variable per pattern scan.** The router holds "the trip I am currently
riding" while walking forward along the pattern, and only re-searches for an
earlier trip when the label at the current stop makes one catchable. This is why
each pattern is touched once per round instead of once per stop.

## The part the papers gloss over: service days

GTFS times are seconds from midnight of a *service day*, and they legally exceed
86400 — the 00:35 night bus is Saturday's service at 88500 seconds. A query at
00:20 on Sunday must therefore consider trips from Saturday's service.

The engine works in one frame: seconds since midnight of the query's base date.
Every trip lookup evaluates three service-day offsets:

| offset | meaning | time in query frame |
|---|---|---|
| −1 | yesterday's service, still running | `tripTime − 86400` |
| 0 | today's service | `tripTime` |
| +1 | tomorrow's service, for arrive-by and long searches | `tripTime + 86400` |

For each offset the router checks `isServiceActive(service, dayIndex + offset)`
against the calendar bitset and takes the best candidate. Skipping the −1 offset
is the single most common bug in hand-rolled transit routers: everything works
perfectly until someone plans a trip at half past midnight and the app tells them
there are no buses, while one is pulling up outside.

## Finding the earliest catchable trip

Within a pattern, trips are stored contiguously and sorted by departure time. The
importer's overtaking split guarantees that this ordering holds at *every*
position, not just the first — so the router can binary-search on departure at
the scan position, then walk forward to the first trip whose service is actually
active on the day being considered.

Binary search gives `O(log T)`; the forward walk is short in practice because
inactive services cluster (a weekday-only pattern has all its trips inactive on a
Sunday, and the router bails out of that pattern immediately).

## Multiple results: range-RAPTOR

A single RAPTOR run answers "leaving now, what is the earliest arrival?" A rider
wants "and what about the next three?".

Range-RAPTOR (rRAPTOR) runs the search from each distinct departure time in the
window, **latest first**. Running backwards through departure times means labels
from the later run remain valid lower bounds for the earlier one, so each
additional departure costs a fraction of a full search rather than a whole one.

The resulting journeys are then reduced to a Pareto set on three criteria:

> A dominates B if A departs no earlier, arrives no later, and uses no more
> transfers — with at least one of those strictly better.

Anything dominated is dropped, because there is no rider preference under which
it is the right answer.

## Arrive-by

The mirrored search: start from the destination, walk time backwards, take
*latest departure* instead of earliest arrival, scan patterns in reverse stop
order. Structurally identical, and it produces the answer riders actually want —
the latest you can leave and still make it.

## Complexity and measured cost

Per round the work is bounded by the number of (pattern, stop) slots touched, so
a full search is `O(K · (‖patterns‖ + ‖transfers‖))` for K rounds — linear in the
size of the network, with no log factors outside the trip search.

Concretely, on a metro feed of ~15,000 stops and ~2M stop-times, with 5 rounds:

| | |
|---|---|
| patterns scanned per query | ~3,000–8,000 |
| journey plan, p50 | ~30–80 ms |
| journey plan, p95 (rRAPTOR, 1 h window) | ~200–400 ms |
| nearby departures board | ~5–15 ms |
| working set touched | a few MB of a ~150 MB file |

These are design targets; `GOAL.md` records them as acceptance criteria, and
`PlanStatistics` is returned with every result so they can be asserted in tests
and shown in a debug HUD rather than guessed at.

## What is deliberately not implemented

- **Multi-criteria beyond (time, transfers).** No fare optimisation, no
  crowding, no walking-distance dimension in the Pareto set. Each extra criterion
  multiplies the label set; the honest v1 answer is to expose walking distance as
  a *constraint* (a cap) rather than as an objective.
- **Transfer patterns / contraction hierarchies.** These make queries faster in
  exchange for an expensive preprocessing step. RAPTOR is already fast enough
  here, and preprocessing time is the scarce resource on a phone, not query time.
- **Street-network walking.** Straight line × detour factor. See `ARCHITECTURE.md`.
