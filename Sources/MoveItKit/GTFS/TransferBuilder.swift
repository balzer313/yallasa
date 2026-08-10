import Foundation

/// Builds the footpath graph RAPTOR walks between rounds.
///
/// RAPTOR's correctness rests on one property the feed never provides: the
/// footpath set must be transitively closed. If A→B and B→C are both walkable but
/// A→C is not in the table, the algorithm will never find the journey that walks
/// through B without boarding there, because it only relaxes footpaths once per
/// round. So the declared transfers and the generated proximity footpaths are
/// both treated as raw edges, and what is actually emitted is the bounded
/// transitive closure over them.
///
/// The closure is bounded twice over — by `maxTransferSeconds` and by an
/// out-degree cap — because in a dense downtown the unbounded closure is
/// quadratic in the number of stops and would dwarf the timetable itself.
enum TransferBuilder {

    /// A `transfers.txt` row, already resolved to graph stop indices.
    struct Seed {
        var from: StopIndex
        var to: StopIndex
        /// `min_transfer_time`, or negative when the feed declares none.
        var seconds: Int32
        /// `transfer_type = 3`: the agency says this transfer is impossible.
        var isForbidden: Bool

        init(from: StopIndex, to: StopIndex, seconds: Int32, isForbidden: Bool) {
            self.from = from
            self.to = to
            self.seconds = seconds
            self.isForbidden = isForbidden
        }
    }

    struct Result {
        /// CSR over the stop table.
        var starts: [UInt32]
        var counts: [UInt32]
        var targets: [Int32]
        var seconds: [Int32]
        var meters: [Int32]
        var forbiddenPairs: Int
    }

    /// Beyond this a stop's footpath list stops describing "places you can walk
    /// to" and starts describing "the neighbourhood", at a cost the router pays
    /// in every round of every query.
    static let maximumOutDegree = 32

    /// A station with more platforms than this gets no all-pairs sibling mesh;
    /// the quadratic term is not worth it and the proximity pass covers it.
    private static let maximumSiblingMesh = 128

    private struct Edge {
        var seconds: Int32
        var meters: Int32
        /// Declared transfers outrank generated ones and are never undercut by a
        /// walking estimate: the agency knows about the locked gate, we do not.
        var declared: Bool
    }

    private struct HeapEntry {
        var seconds: Int32
        var stop: Int32
    }

    private struct MinHeap {
        private var items: [HeapEntry] = []

        mutating func removeAll() { items.removeAll(keepingCapacity: true) }

        mutating func push(_ entry: HeapEntry) {
            items.append(entry)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                if items[parent].seconds <= items[child].seconds { break }
                items.swapAt(parent, child)
                child = parent
            }
        }

        mutating func pop() -> HeapEntry? {
            guard !items.isEmpty else { return nil }
            let top = items[0]
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    let right = left + 1
                    var smallest = parent
                    if left < items.count, items[left].seconds < items[smallest].seconds { smallest = left }
                    if right < items.count, items[right].seconds < items[smallest].seconds { smallest = right }
                    if smallest == parent { break }
                    items.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return top
        }
    }

    static func build(
        coordinates: [GeoPoint],
        isStation: [Bool],
        parents: [StopIndex],
        seeds: [Seed],
        options: GraphMetadata.BuildOptions
    ) -> Result {
        let stopCount = coordinates.count
        guard stopCount > 0 else {
            return Result(starts: [], counts: [], targets: [], seconds: [], meters: [], forbiddenPairs: 0)
        }

        let minimumSeconds = Int32(clamping: options.minimumTransferSeconds)
        let limitSeconds = Int32(clamping: max(options.maxTransferSeconds, options.minimumTransferSeconds))
        let walkSpeed = max(0.1, options.walkingSpeedMetersPerSecond)
        let detour = max(1.0, options.walkingDetourFactor)

        func walkingSeconds(_ meters: Double) -> Int32 {
            let raw = (meters * detour / walkSpeed).rounded()
            let capped = min(max(raw, 0), 1_000_000)
            return max(minimumSeconds, Int32(capped))
        }

        func metersValue(_ meters: Double) -> Int32 {
            Int32(min(max(meters.rounded(), 0), 2_000_000_000))
        }

        // Children by station, used both to mesh platforms and to push a
        // station-level `transfers.txt` row down onto the platforms the router
        // actually boards at.
        var childrenByParent: [Int32: [Int32]] = [:]
        for stop in 0..<stopCount {
            let parent = parents[stop]
            if parent >= 0, Int(parent) < stopCount {
                childrenByParent[parent, default: []].append(Int32(stop))
            }
        }

        func expanded(_ stop: Int32) -> [Int32] {
            guard stop >= 0, Int(stop) < stopCount, isStation[Int(stop)] else { return [stop] }
            if let children = childrenByParent[stop], !children.isEmpty { return children }
            return [stop]
        }

        // MARK: Forbidden pairs

        var forbidden = Set<Int64>()
        var forbiddenPairs = 0
        for seed in seeds where seed.isForbidden {
            guard seed.from >= 0, Int(seed.from) < stopCount, seed.to >= 0, Int(seed.to) < stopCount else { continue }
            let sources = expanded(seed.from)
            let targets = expanded(seed.to)
            guard sources.count * targets.count <= 4096 else { continue }
            for source in sources {
                for target in targets where source != target {
                    if forbidden.insert(Int64(source) &* Int64(stopCount) &+ Int64(target)).inserted {
                        forbiddenPairs += 1
                    }
                }
            }
        }
        let hasForbidden = !forbidden.isEmpty

        func isForbidden(_ from: Int32, _ to: Int32) -> Bool {
            guard hasForbidden else { return false }
            return forbidden.contains(Int64(from) &* Int64(stopCount) &+ Int64(to))
        }

        // MARK: Raw edges

        var adjacency = [[Int32: Edge]](repeating: [:], count: stopCount)

        func insert(from: Int32, to: Int32, seconds: Int32, meters: Int32, declared: Bool) {
            guard from != to, from >= 0, to >= 0, Int(from) < stopCount, Int(to) < stopCount else { return }
            guard !isForbidden(from, to) else { return }
            let candidate = Edge(seconds: seconds, meters: meters, declared: declared)
            guard let existing = adjacency[Int(from)][to] else {
                adjacency[Int(from)][to] = candidate
                return
            }
            if existing.declared != declared {
                if declared { adjacency[Int(from)][to] = candidate }
                return
            }
            if seconds < existing.seconds { adjacency[Int(from)][to] = candidate }
        }

        for seed in seeds where !seed.isForbidden {
            guard seed.from >= 0, Int(seed.from) < stopCount, seed.to >= 0, Int(seed.to) < stopCount else { continue }
            let sources = expanded(seed.from)
            let targets = expanded(seed.to)
            guard sources.count * targets.count <= 4096 else { continue }
            for source in sources {
                for target in targets where source != target {
                    let distance = coordinates[Int(source)].approximateDistance(to: coordinates[Int(target)])
                    let seconds = seed.seconds >= 0
                        ? max(seed.seconds, minimumSeconds)
                        : walkingSeconds(distance)
                    insert(
                        from: source,
                        to: target,
                        seconds: seconds,
                        meters: metersValue(distance),
                        declared: true
                    )
                }
            }
        }

        // Platforms of one station are always mutually reachable, whatever the
        // proximity radius says — a long island platform can exceed it.
        for (_, siblings) in childrenByParent where siblings.count > 1 {
            guard siblings.count <= maximumSiblingMesh else { continue }
            for left in 0..<siblings.count {
                for right in 0..<siblings.count where left != right {
                    let distance = coordinates[Int(siblings[left])]
                        .approximateDistance(to: coordinates[Int(siblings[right])])
                    insert(
                        from: siblings[left],
                        to: siblings[right],
                        seconds: walkingSeconds(distance),
                        meters: metersValue(distance),
                        declared: false
                    )
                }
            }
        }

        // MARK: Generated proximity footpaths
        //
        // A uniform grid with cells the size of the search radius means each stop
        // only ever compares against the nine cells around it, which is what turns
        // an O(n²) all-pairs scan into something linear in practice.
        let radius = options.maxTransferMeters
        if radius > 0 {
            var cellLatitude = GeoPoint.latitudeDegrees(forMeters: radius)
            if !cellLatitude.isFinite || cellLatitude <= 0 { cellLatitude = 0.01 }
            var averageLatitude = 0.0
            for point in coordinates { averageLatitude += point.latitude }
            averageLatitude /= Double(stopCount)
            var cellLongitude = GeoPoint(latitude: averageLatitude, longitude: 0).longitudeDegrees(forMeters: radius)
            if !cellLongitude.isFinite || cellLongitude <= 0 { cellLongitude = cellLatitude }
            cellLongitude = min(cellLongitude, 10)

            var buckets: [Int64: [Int32]] = [:]
            var cellRow = [Int32](repeating: 0, count: stopCount)
            var cellColumn = [Int32](repeating: 0, count: stopCount)
            for stop in 0..<stopCount where !isStation[stop] {
                let row = Int32(clamping: Int((coordinates[stop].latitude / cellLatitude).rounded(.down)))
                let column = Int32(clamping: Int((coordinates[stop].longitude / cellLongitude).rounded(.down)))
                cellRow[stop] = row
                cellColumn[stop] = column
                buckets[Int64(row) &* 8_000_000 &+ Int64(column), default: []].append(Int32(stop))
            }

            for stop in 0..<stopCount where !isStation[stop] {
                let row = cellRow[stop]
                let column = cellColumn[stop]
                for rowOffset in -1...1 {
                    for columnOffset in -1...1 {
                        let key = Int64(row + Int32(rowOffset)) &* 8_000_000 &+ Int64(column + Int32(columnOffset))
                        guard let bucketStops = buckets[key] else { continue }
                        for candidate in bucketStops where Int(candidate) > stop {
                            let distance = coordinates[stop].approximateDistance(to: coordinates[Int(candidate)])
                            guard distance <= radius else { continue }
                            let seconds = walkingSeconds(distance)
                            let meters = metersValue(distance)
                            insert(from: Int32(stop), to: candidate, seconds: seconds, meters: meters, declared: false)
                            insert(from: candidate, to: Int32(stop), seconds: seconds, meters: meters, declared: false)
                        }
                    }
                }
            }
        }

        // MARK: Bounded transitive closure
        //
        // Flattened to CSR first: the closure runs one Dijkstra per stop, and
        // walking a dictionary of dictionaries that many times is most of the
        // import's transfer budget.
        var neighbourStart = [Int](repeating: 0, count: stopCount + 1)
        var neighbourTarget: [Int32] = []
        var neighbourSeconds: [Int32] = []
        var neighbourMeters: [Int32] = []
        for stop in 0..<stopCount {
            neighbourStart[stop] = neighbourTarget.count
            for (target, edge) in adjacency[stop] {
                neighbourTarget.append(target)
                neighbourSeconds.append(edge.seconds)
                neighbourMeters.append(edge.meters)
            }
        }
        neighbourStart[stopCount] = neighbourTarget.count

        var distance = [Int32](repeating: Int32.max, count: stopCount)
        var metersTo = [Int32](repeating: 0, count: stopCount)
        // Generation stamping instead of clearing: at 50k stops the clears alone
        // would be 2.5 billion writes.
        var stamp = [Int32](repeating: -1, count: stopCount)
        var touched: [Int32] = []
        var heap = MinHeap()

        var starts = [UInt32](repeating: 0, count: stopCount)
        var counts = [UInt32](repeating: 0, count: stopCount)
        var outTargets: [Int32] = []
        var outSeconds: [Int32] = []
        var outMeters: [Int32] = []

        var candidates: [(target: Int32, seconds: Int32, meters: Int32)] = []

        for source in 0..<stopCount {
            let generation = Int32(source)
            touched.removeAll(keepingCapacity: true)
            heap.removeAll()
            stamp[source] = generation
            distance[source] = 0
            metersTo[source] = 0
            heap.push(HeapEntry(seconds: 0, stop: Int32(source)))

            while let top = heap.pop() {
                if top.seconds > limitSeconds { break }
                let current = Int(top.stop)
                guard stamp[current] == generation, top.seconds <= distance[current] else { continue }
                let lower = neighbourStart[current]
                let upper = neighbourStart[current + 1]
                guard lower < upper else { continue }
                for slot in lower..<upper {
                    let target = neighbourTarget[slot]
                    let reached = top.seconds &+ neighbourSeconds[slot]
                    guard reached <= limitSeconds else { continue }
                    guard !isForbidden(Int32(source), target) else { continue }
                    let targetIndex = Int(target)
                    if stamp[targetIndex] != generation {
                        stamp[targetIndex] = generation
                        distance[targetIndex] = reached
                        metersTo[targetIndex] = metersTo[current] &+ neighbourMeters[slot]
                        touched.append(target)
                        heap.push(HeapEntry(seconds: reached, stop: target))
                    } else if reached < distance[targetIndex] {
                        distance[targetIndex] = reached
                        metersTo[targetIndex] = metersTo[current] &+ neighbourMeters[slot]
                        heap.push(HeapEntry(seconds: reached, stop: target))
                    }
                }
            }

            candidates.removeAll(keepingCapacity: true)
            for target in touched where Int(target) != source {
                candidates.append((target: target, seconds: distance[Int(target)], meters: metersTo[Int(target)]))
            }

            // A shortcut through a third stop must not undercut a minimum the
            // agency declared for the direct move.
            for (target, edge) in adjacency[source] where edge.declared {
                guard let position = candidates.firstIndex(where: { $0.target == target }) else { continue }
                if candidates[position].seconds < edge.seconds {
                    candidates[position].seconds = edge.seconds
                }
            }

            candidates.sort { left, right in
                if left.seconds != right.seconds { return left.seconds < right.seconds }
                if left.meters != right.meters { return left.meters < right.meters }
                return left.target < right.target
            }
            if candidates.count > maximumOutDegree {
                candidates.removeSubrange(maximumOutDegree...)
            }

            starts[source] = UInt32(clamping: outTargets.count)
            counts[source] = UInt32(clamping: candidates.count)
            for candidate in candidates {
                outTargets.append(candidate.target)
                outSeconds.append(candidate.seconds)
                outMeters.append(candidate.meters)
            }
        }

        return Result(
            starts: starts,
            counts: counts,
            targets: outTargets,
            seconds: outSeconds,
            meters: outMeters,
            forbiddenPairs: forbiddenPairs
        )
    }
}
