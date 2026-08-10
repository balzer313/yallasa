import Foundation

/// Groups trips into the patterns RAPTOR treats as "routes".
///
/// A pattern is a maximal set of trips that call at the same stops, in the same
/// order, with the same boarding rules, on the same GTFS route. RAPTOR scans a
/// pattern once per round and binary-searches its trips for the earliest one it
/// can catch, which is only sound if the trips are sorted by departure at *every*
/// position — not merely at the first. Feeds violate that (an express overtakes a
/// local it shares a stop list with), so patterns whose trips cannot be totally
/// ordered are split until they can be.
///
/// Trips are accumulated as they stream out of `stop_times.txt` and held as flat
/// integer columns, so the peak cost of grouping is the stop-time data itself
/// rather than a per-trip object graph.
final class PatternBuilder {

    struct Pattern {
        var route: RouteIndex
        var stops: [StopIndex]
        var pickups: [UInt8]
        var dropOffs: [UInt8]
        /// Indices into the importer's trip attribute table, in departure order.
        /// A frequency-expanded trip appears once per generated departure.
        var sourceTrips: [TripIndex]
        /// `sourceTrips.count * stops.count`, trip-major — exactly the layout
        /// `TransitGraph.stopTimeIndex(pattern:tripOffset:position:)` expects.
        var arrivals: [ServiceSeconds]
        var departures: [ServiceSeconds]
    }

    struct Result {
        var patterns: [Pattern]
        /// Extra patterns created purely because trips overtook one another.
        var overtakingSplits: Int
    }

    private struct Group {
        var route: RouteIndex
        var stops: [StopIndex]
        var pickups: [UInt8]
        var dropOffs: [UInt8]
        var sourceTrips: [TripIndex]
        var arrivals: [ServiceSeconds]
        var departures: [ServiceSeconds]
    }

    private var groups: [Group] = []
    private var groupIndexByKey: [[Int64]: Int] = [:]

    init() {}

    var isEmpty: Bool { groups.isEmpty }

    /// Files one trip. Times must already be complete — interpolation happens
    /// upstream, because it needs the geometry the builder does not carry.
    func add(
        sourceTrip: TripIndex,
        route: RouteIndex,
        stops: [StopIndex],
        pickups: [UInt8],
        dropOffs: [UInt8],
        arrivals: [ServiceSeconds],
        departures: [ServiceSeconds]
    ) {
        let stopCount = stops.count
        guard stopCount >= 2,
              pickups.count == stopCount,
              dropOffs.count == stopCount,
              arrivals.count == stopCount,
              departures.count == stopCount
        else { return }

        // One packed array rather than three, so the dictionary hashes and
        // compares a single contiguous buffer per trip.
        var key = [Int64](repeating: 0, count: stopCount + 1)
        key[0] = Int64(route)
        for position in 0..<stopCount {
            key[position + 1] = Int64(stops[position]) &* 16
                &+ Int64(pickups[position] & 0b11) &* 4
                &+ Int64(dropOffs[position] & 0b11)
        }

        let groupIndex: Int
        if let existing = groupIndexByKey[key] {
            groupIndex = existing
        } else {
            groupIndex = groups.count
            groupIndexByKey[key] = groupIndex
            groups.append(
                Group(
                    route: route,
                    stops: stops,
                    pickups: pickups,
                    dropOffs: dropOffs,
                    sourceTrips: [],
                    arrivals: [],
                    departures: []
                )
            )
        }

        groups[groupIndex].sourceTrips.append(sourceTrip)
        groups[groupIndex].arrivals.append(contentsOf: arrivals)
        groups[groupIndex].departures.append(contentsOf: departures)
    }

    func finish() -> Result {
        var patterns: [Pattern] = []
        var splits = 0
        patterns.reserveCapacity(groups.count)

        for group in groups {
            let stopCount = group.stops.count
            let tripCount = group.sourceTrips.count
            guard stopCount >= 2, tripCount > 0 else { continue }

            var order = Array(0..<tripCount)
            order.sort { lhs, rhs in
                let left = group.departures[lhs * stopCount]
                let right = group.departures[rhs * stopCount]
                if left != right { return left < right }
                // Stable enough to make a rebuild of the same feed reproducible.
                return group.sourceTrips[lhs] < group.sourceTrips[rhs]
            }

            // Greedy chain decomposition. Because `order` is already sorted by
            // first departure, a bucket stays totally ordered as long as each new
            // trip dominates the one currently at its end, so only that one trip
            // needs comparing.
            var buckets: [[Int]] = []
            var bucketTail: [Int] = []
            for trip in order {
                var placed = false
                for bucket in 0..<buckets.count {
                    guard PatternBuilder.isOrdered(
                        previous: bucketTail[bucket],
                        next: trip,
                        stopCount: stopCount,
                        arrivals: group.arrivals,
                        departures: group.departures
                    ) else { continue }
                    buckets[bucket].append(trip)
                    bucketTail[bucket] = trip
                    placed = true
                    break
                }
                if !placed {
                    if !buckets.isEmpty { splits += 1 }
                    buckets.append([trip])
                    bucketTail.append(trip)
                }
            }

            for bucket in buckets {
                var arrivals: [ServiceSeconds] = []
                var departures: [ServiceSeconds] = []
                var sourceTrips: [TripIndex] = []
                arrivals.reserveCapacity(bucket.count * stopCount)
                departures.reserveCapacity(bucket.count * stopCount)
                sourceTrips.reserveCapacity(bucket.count)

                for trip in bucket {
                    sourceTrips.append(group.sourceTrips[trip])
                    let base = trip * stopCount
                    arrivals.append(contentsOf: group.arrivals[base ..< (base + stopCount)])
                    departures.append(contentsOf: group.departures[base ..< (base + stopCount)])
                }

                patterns.append(
                    Pattern(
                        route: group.route,
                        stops: group.stops,
                        pickups: group.pickups,
                        dropOffs: group.dropOffs,
                        sourceTrips: sourceTrips,
                        arrivals: arrivals,
                        departures: departures
                    )
                )
            }
        }

        return Result(patterns: patterns, overtakingSplits: splits)
    }

    /// Whether `next` may follow `previous` in the same pattern.
    ///
    /// Departures are checked because that is what the trip search binary-searches
    /// on; arrivals are checked because the round's "earliest arrival" bookkeeping
    /// assumes the trip that departs first also arrives first. A feed can violate
    /// either independently.
    private static func isOrdered(
        previous: Int,
        next: Int,
        stopCount: Int,
        arrivals: [ServiceSeconds],
        departures: [ServiceSeconds]
    ) -> Bool {
        let previousBase = previous * stopCount
        let nextBase = next * stopCount
        for position in 0..<stopCount {
            if departures[nextBase + position] < departures[previousBase + position] { return false }
            if arrivals[nextBase + position] < arrivals[previousBase + position] { return false }
        }
        return true
    }
}
