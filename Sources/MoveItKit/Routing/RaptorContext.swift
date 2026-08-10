import Foundation

/// One RAPTOR label: when you can be at a stop, and how you got there.
///
/// The router stores labels in a flat `round * stopCount + stop` array rather
/// than as a graph of objects. Reconstruction walks *backwards* through these
/// fields, so every label has to carry enough to name its own last leg and
/// address its predecessor — but no more than that, because this struct is
/// multiplied by rounds × stops and a metro feed has fifty thousand stops.
///
/// The same struct serves the forward and the backward search. In the backward
/// search `time` is the *latest departure* rather than the earliest arrival and
/// `linkStop` names the *next* stop rather than the previous one; the field
/// comments call this out where it matters.
struct RaptorLabel {
    /// Earliest arrival (forward) or latest departure (backward), in the query's
    /// single time frame: seconds from midnight of the query base date.
    var time: Int32 = noTime
    /// Cumulative walking metres on the path that produced this label, used to
    /// enforce `PlanOptions.maximumTotalWalkMeters`.
    var walkMeters: Int32 = 0

    /// `noIndex` when this label was produced by walking (or by access seeding).
    var pattern: PatternIndex = noIndex
    var tripOffset: Int32 = -1
    /// Service day this trip belongs to, relative to the query base date: −1, 0
    /// or +1. Needed to report `RideLeg.serviceDate` and to translate the
    /// timetable's own frame back into the query frame.
    var dayOffset: Int32 = 0
    var boardPosition: Int32 = -1
    var alightPosition: Int32 = -1

    /// For a walk label, the stop walked *from* (forward) or *to* (backward).
    /// `noIndex` on an access/egress seed label, which terminates the chain.
    var linkStop: StopIndex = noIndex
    var legWalkSeconds: Int32 = 0
    var legWalkMeters: Int32 = 0

    /// The last pattern ridden on the path to this label, or `noIndex` if none.
    ///
    /// Carried through walk labels so that `minimumTransferSeconds` can be
    /// charged for boarding a *different* line than the one just left, and not
    /// charged for the very first boarding of a journey.
    var lastRidePattern: PatternIndex = noIndex

    /// True when this label is a ride rather than a walk.
    @inline(__always) var isRide: Bool { pattern != noIndex }
    /// True when the chain ends here: the rider's own origin (or destination).
    @inline(__always) var isSeed: Bool { pattern == noIndex && linkStop == noIndex }
}

/// Per-query scratch state for RAPTOR.
///
/// Everything mutable the router touches lives here and nowhere else, which is
/// what makes `JourneyPlanner` safe to use from several tasks against one
/// `TransitGraph` at the same time.
///
/// The arrays are allocated once per query and reused across all rounds *and*
/// across every departure of the range-RAPTOR sweep. They are never re-zeroed:
/// each slot carries a generation stamp, and a slot whose stamp does not match
/// the current generation reads as "unset". Bumping one `UInt32` therefore
/// clears a multi-megabyte label array in constant time, which matters because
/// a range query over an hour-long window runs the clear dozens of times.
final class RaptorContext {
    let graph: TransitGraph
    let stopCount: Int
    let patternCount: Int
    /// Includes round 0 (access on foot), so this is `maximumTransfers + 2`.
    let roundCount: Int

    /// The value a label reads as when it has never been set. `noTime`
    /// (`Int32.max`) going forward, `Int32.min` going backward, so that
    /// "improvement" is always a plain `<` or `>` against it.
    private(set) var unsetValue: Int32 = noTime

    // Labels, indexed `round * stopCount + stop`.
    private var labels: ContiguousArray<RaptorLabel>
    private var labelStamps: ContiguousArray<UInt32>

    // Best value over all rounds, for local pruning.
    private var bestValues: ContiguousArray<Int32>
    private var bestStamps: ContiguousArray<UInt32>

    private var generation: UInt32 = 0

    // Marked stops, as a stamped membership test plus a dense list to iterate.
    private var markStamps: ContiguousArray<UInt32>
    private var markGeneration: UInt32 = 0
    private(set) var markedStops: [StopIndex] = []

    // The route queue: pattern -> the extreme marked position along it.
    private var queueStamps: ContiguousArray<UInt32>
    private var queuePositions: ContiguousArray<Int32>
    private var queueGeneration: UInt32 = 0
    private(set) var queuedPatterns: [PatternIndex] = []

    /// Which of the three service-day offsets a pattern has any active trip on,
    /// as bits 0/1/2 for −1/0/+1. Computed lazily on first touch of a pattern
    /// and reused for the rest of the query: without it, a pattern whose service
    /// does not run today costs a full trip scan on every single lookup.
    private var patternDayMasks: ContiguousArray<UInt8>
    private var patternDayStamps: ContiguousArray<UInt32>

    /// Snapshot of the labels a round's footpath relaxation reads from.
    ///
    /// Footpaths are transitively closed in the graph, so relaxation must be a
    /// single non-chaining pass. Reading live labels would let stop A improve B
    /// and then B improve A back again through the same edge, which builds a
    /// two-step walk out of one closed footpath — and, worse, a parent-pointer
    /// cycle that reconstruction cannot escape.
    private var transferSources: [(stop: StopIndex, time: Int32, walkMeters: Int32, lastRidePattern: PatternIndex)] = []

    // Budget.
    private var startedAt: Date = Date()
    private var timeLimitSeconds: Double = .greatestFiniteMagnitude
    private(set) var hitTimeLimit = false

    var statistics = PlanStatistics()

    init(graph: TransitGraph, maximumTransfers: Int) {
        self.graph = graph
        self.stopCount = graph.stopCount
        self.patternCount = graph.patternCount
        self.roundCount = max(1, maximumTransfers + 2)

        let slotCount = roundCount * max(stopCount, 1)
        self.labels = ContiguousArray(repeating: RaptorLabel(), count: slotCount)
        self.labelStamps = ContiguousArray(repeating: 0, count: slotCount)
        self.bestValues = ContiguousArray(repeating: noTime, count: max(stopCount, 1))
        self.bestStamps = ContiguousArray(repeating: 0, count: max(stopCount, 1))
        self.markStamps = ContiguousArray(repeating: 0, count: max(stopCount, 1))
        self.queueStamps = ContiguousArray(repeating: 0, count: max(patternCount, 1))
        self.queuePositions = ContiguousArray(repeating: 0, count: max(patternCount, 1))
        self.patternDayMasks = ContiguousArray(repeating: 0, count: max(patternCount, 1))
        self.patternDayStamps = ContiguousArray(repeating: 0, count: max(patternCount, 1))
        self.markedStops.reserveCapacity(256)
        self.queuedPatterns.reserveCapacity(256)
        self.transferSources.reserveCapacity(256)
    }

    // MARK: - Lifecycle

    /// Invalidates every label and cache in constant time and points the
    /// comparison sentinel in the right direction.
    func begin(forward: Bool, timeLimitSeconds limit: Double) {
        generation &+= 1
        // A wrapped generation would make stale slots read as live, so on the
        // (astronomically unlikely) wrap we pay for one honest clear.
        if generation == 0 {
            for index in labelStamps.indices { labelStamps[index] = 0 }
            for index in bestStamps.indices { bestStamps[index] = 0 }
            for index in patternDayStamps.indices { patternDayStamps[index] = 0 }
            generation = 1
        }
        unsetValue = forward ? noTime : Int32.min
        markGeneration &+= 1
        queueGeneration &+= 1
        markedStops.removeAll(keepingCapacity: true)
        queuedPatterns.removeAll(keepingCapacity: true)
        startedAt = Date()
        timeLimitSeconds = limit
        hitTimeLimit = false
        statistics = PlanStatistics()
    }

    /// True once the wall-clock budget is spent. Checked at round boundaries and
    /// between range iterations, never in the inner loop — the check itself is a
    /// syscall-ish cost and the router would spend its budget measuring it.
    func checkDeadline() -> Bool {
        if hitTimeLimit { return true }
        if Date().timeIntervalSince(startedAt) >= timeLimitSeconds {
            hitTimeLimit = true
        }
        return hitTimeLimit
    }

    var elapsedSeconds: Double { Date().timeIntervalSince(startedAt) }

    // MARK: - Labels

    @inline(__always)
    func label(round: Int, stop: StopIndex) -> RaptorLabel {
        let index = round * stopCount + Int(stop)
        if labelStamps[index] != generation {
            var empty = RaptorLabel()
            empty.time = unsetValue
            return empty
        }
        return labels[index]
    }

    @inline(__always)
    func setLabel(_ label: RaptorLabel, round: Int, stop: StopIndex) {
        let index = round * stopCount + Int(stop)
        labels[index] = label
        labelStamps[index] = generation
    }

    @inline(__always)
    func hasLabel(round: Int, stop: StopIndex) -> Bool {
        labelStamps[round * stopCount + Int(stop)] == generation
    }

    @inline(__always)
    func best(stop: StopIndex) -> Int32 {
        let index = Int(stop)
        return bestStamps[index] == generation ? bestValues[index] : unsetValue
    }

    @inline(__always)
    func setBest(_ value: Int32, stop: StopIndex) {
        let index = Int(stop)
        bestValues[index] = value
        bestStamps[index] = generation
    }

    // MARK: - Marks

    @inline(__always)
    func clearMarks() {
        markGeneration &+= 1
        markedStops.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    func mark(stop: StopIndex) {
        let index = Int(stop)
        guard markStamps[index] != markGeneration else { return }
        markStamps[index] = markGeneration
        markedStops.append(stop)
    }

    @inline(__always)
    func isMarked(stop: StopIndex) -> Bool { markStamps[Int(stop)] == markGeneration }

    // MARK: - Route queue

    /// Rebuilds the pattern queue from the currently marked stops.
    ///
    /// `preferLater` picks the *latest* marked position along a pattern instead
    /// of the earliest, which is what the backward search needs: it walks
    /// patterns from their far end towards their start.
    func buildQueue(preferLater: Bool) {
        queueGeneration &+= 1
        queuedPatterns.removeAll(keepingCapacity: true)
        for stop in markedStops {
            for slot in graph.patternSlots(atStop: stop) {
                let pattern = graph.stopPatternReferences[slot]
                guard pattern >= 0, Int(pattern) < patternCount else { continue }
                let position = Int32(graph.stopPatternPositions[slot])
                let index = Int(pattern)
                if queueStamps[index] != queueGeneration {
                    queueStamps[index] = queueGeneration
                    queuePositions[index] = position
                    queuedPatterns.append(pattern)
                } else if preferLater {
                    if position > queuePositions[index] { queuePositions[index] = position }
                } else {
                    if position < queuePositions[index] { queuePositions[index] = position }
                }
            }
        }
    }

    @inline(__always)
    func queuedPosition(of pattern: PatternIndex) -> Int { Int(queuePositions[Int(pattern)]) }

    // MARK: - Day-offset cache

    /// Bit `offset + 1` is set when the pattern has at least one trip whose
    /// service runs on `baseDayIndex + offset`.
    func dayMask(forPattern pattern: PatternIndex, baseDayIndex: Int) -> UInt8 {
        let index = Int(pattern)
        if patternDayStamps[index] == generation { return patternDayMasks[index] }
        var mask: UInt8 = 0
        let trips = graph.tripRange(ofPattern: pattern)
        for offset in -1...1 {
            let day = baseDayIndex + offset
            guard day >= 0, day < graph.metadata.calendarDayCount else { continue }
            for trip in trips where graph.isServiceActive(graph.tripService(TripIndex(trip)), dayIndex: day) {
                mask |= UInt8(1 << (offset + 1))
                break
            }
        }
        patternDayMasks[index] = mask
        patternDayStamps[index] = generation
        return mask
    }

    // MARK: - Transfer snapshot

    func snapshotTransferSources(round: Int) {
        transferSources.removeAll(keepingCapacity: true)
        for stop in markedStops {
            let label = label(round: round, stop: stop)
            guard label.time != unsetValue else { continue }
            transferSources.append(
                (stop: stop, time: label.time, walkMeters: label.walkMeters, lastRidePattern: label.lastRidePattern)
            )
        }
    }

    var pendingTransferSources: [(stop: StopIndex, time: Int32, walkMeters: Int32, lastRidePattern: PatternIndex)] {
        transferSources
    }
}
