import Foundation
@testable import YallaSaKit

/// A hand-controlled realtime snapshot.
///
/// Keyed the same way `RealtimeIndex` keys its own table, so a test that sets a
/// delay here exercises the same lookup shape the real overlay uses.
final class StubRealtimeSource: RealtimeSource, @unchecked Sendable {
    var generatedAt: Date = Date(timeIntervalSince1970: 1_776_000_000)

    private var adjustments: [Int64: RealtimeAdjustment] = [:]
    private var cancelledTrips: Set<TripIndex> = []

    var coveredTripCount: Int { max(adjustments.count, cancelledTrips.count) }

    func adjustment(trip: TripIndex, position: Int) -> RealtimeAdjustment? {
        adjustments[StubRealtimeSource.key(trip: trip, position: position)]
    }

    func isCancelled(trip: TripIndex) -> Bool { cancelledTrips.contains(trip) }

    // MARK: - Test control

    /// Applies a uniform delay to every position of a trip, which is what a feed
    /// reporting a late-running vehicle looks like after propagation.
    func setDelay(_ seconds: Int32, trip: TripIndex, positions: Int) {
        for position in 0..<positions {
            adjustments[StubRealtimeSource.key(trip: trip, position: position)] =
                RealtimeAdjustment(arrivalDelay: seconds, departureDelay: seconds)
        }
    }

    func cancel(trip: TripIndex, positions: Int) {
        cancelledTrips.insert(trip)
        for position in 0..<positions {
            adjustments[StubRealtimeSource.key(trip: trip, position: position)] =
                RealtimeAdjustment(isCancelled: true)
        }
    }

    func skip(trip: TripIndex, position: Int) {
        adjustments[StubRealtimeSource.key(trip: trip, position: position)] =
            RealtimeAdjustment(isSkipped: true)
    }

    private static func key(trip: TripIndex, position: Int) -> Int64 {
        (Int64(trip) << 20) | Int64(position)
    }
}
