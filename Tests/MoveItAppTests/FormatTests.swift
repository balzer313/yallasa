import XCTest
@testable import MoveIt

/// Formatting is the one piece of app-layer logic with no UI in it, and it is
/// where the rounding decisions live that determine whether someone catches
/// their bus. Worth testing directly.
final class FormatTests: XCTestCase {
    func testCountdownRoundsUpSoRidersAreNotSentOutLate() {
        // 2:50 must read as 3 min, not 2 — rounding down is how you miss a bus.
        XCTAssertEqual(Format.countdown(seconds: 170), "3 min")
        XCTAssertEqual(Format.countdown(seconds: 121), "3 min")
        XCTAssertEqual(Format.countdown(seconds: 120), "2 min")
    }

    func testCountdownUnderAMinuteReadsAsNow() {
        XCTAssertEqual(Format.countdown(seconds: 59), "now")
        XCTAssertEqual(Format.countdown(seconds: 0), "now")
    }

    func testCountdownPastDeparture() {
        XCTAssertEqual(Format.countdown(seconds: -30), "departed")
    }

    func testCountdownHours() {
        XCTAssertEqual(Format.countdown(seconds: 3600), "1 hr")
        XCTAssertEqual(Format.countdown(seconds: 3600 + 600), "1 hr 10 min")
    }

    func testDurationRoundsToNearestMinute() {
        // Durations are retrospective, so nearest is right where countdown's
        // round-up is right.
        XCTAssertEqual(Format.duration(seconds: 89), "1 min")
        XCTAssertEqual(Format.duration(seconds: 91), "2 min")
        XCTAssertEqual(Format.duration(seconds: 4320), "1 hr 12 min")
    }

    func testTransferCountWording() {
        XCTAssertEqual(Format.transferCount(0), "Direct")
        XCTAssertEqual(Format.transferCount(1), "1 transfer")
        XCTAssertEqual(Format.transferCount(3), "3 transfers")
    }

    func testStopCountSingularAndPlural() {
        XCTAssertEqual(Format.stopCount(1), "1 stop")
        XCTAssertEqual(Format.stopCount(4), "4 stops")
    }

    func testLiveStatusTreatsSubMinuteDeviationAsOnTime() {
        // Feeds routinely report 30-second deviations. Surfacing those as
        // "1 min late" teaches riders to ignore the indicator entirely.
        XCTAssertEqual(LiveStatus(delay: 40, isCancelled: false), .onTime)
        XCTAssertEqual(LiveStatus(delay: -40, isCancelled: false), .onTime)
        XCTAssertEqual(LiveStatus(delay: 300, isCancelled: false), .late(seconds: 300))
        XCTAssertEqual(LiveStatus(delay: -300, isCancelled: false), .early(seconds: 300))
    }

    func testLiveStatusDistinguishesUnknownFromOnTime() {
        // "We have no realtime data" and "it is running on time" are different
        // claims and must not render the same way.
        XCTAssertEqual(LiveStatus(delay: nil, isCancelled: false), .scheduled)
        XCTAssertFalse(LiveStatus(delay: nil, isCancelled: false).isLive)
        XCTAssertTrue(LiveStatus(delay: 0, isCancelled: false).isLive)
    }

    func testCancellationOverridesDelay() {
        XCTAssertEqual(LiveStatus(delay: 120, isCancelled: true), .cancelled)
    }
}
