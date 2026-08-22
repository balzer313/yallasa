import XCTest
import YallaSaKit
@testable import YallaSa

/// The שנ״צ schedule.
///
/// This is the one piece of the app where being wrong has a real cost: a rider
/// asleep on a bus is trusting the alarm completely, and an alarm a minute late
/// is an alarm at the wrong stop. The schedule is pure and static precisely so
/// it can be checked without a notification centre.
final class TripTrackerAlarmTests: XCTestCase {

    private let timeZone = TimeZone(identifier: "Asia/Jerusalem")!
    private let baseDate = ServiceDate(year: 2026, month: 8, day: 25)

    private func leg(
        _ kind: JourneyLegItem.Kind,
        from: String,
        to: String,
        depart: Int,
        arrive: Int,
        line: String? = nil,
        id: String = UUID().uuidString
    ) -> JourneyLegItem {
        JourneyLegItem(
            id: id,
            kind: kind,
            badge: line.map {
                LineBadgeData(
                    text: $0,
                    backgroundHex: 0x10_50_80,
                    foregroundHex: 0xFF_FF_FF,
                    mode: .bus,
                    accessibilityLabel: "line \($0)"
                )
            },
            headsign: to,
            fromName: from,
            toName: to,
            fromStop: nil,
            toStop: nil,
            departureSeconds: ServiceSeconds(depart),
            arrivalSeconds: ServiceSeconds(arrive),
            status: .scheduled,
            distanceMeters: 0,
            intermediateStopCount: 0,
            intermediateStopNames: []
        )
    }

    /// Walk → bus 5 → walk → bus 18 → walk. The realistic shape.
    private func twoRideJourney() -> JourneyItem {
        let legs = [
            leg(.walk, from: "Home", to: "Stop A", depart: 8 * 3600, arrive: 8 * 3600 + 300),
            leg(.ride, from: "Stop A", to: "Stop B", depart: 8 * 3600 + 300, arrive: 8 * 3600 + 1_200, line: "5"),
            leg(.walk, from: "Stop B", to: "Stop C", depart: 8 * 3600 + 1_200, arrive: 8 * 3600 + 1_400),
            leg(.ride, from: "Stop C", to: "Stop D", depart: 8 * 3600 + 1_500, arrive: 8 * 3600 + 2_400, line: "18"),
            leg(.walk, from: "Stop D", to: "Work", depart: 8 * 3600 + 2_400, arrive: 8 * 3600 + 2_700),
        ]
        return JourneyItem(
            id: "j1",
            journey: Journey(legs: [], baseDate: baseDate),
            legs: legs,
            departureSeconds: ServiceSeconds(8 * 3600),
            arrivalSeconds: ServiceSeconds(8 * 3600 + 2_700),
            baseDate: baseDate,
            durationSeconds: 2_700,
            transferCount: 1,
            walkMeters: 400,
            badges: [],
            isWalkOnly: false,
            hasRealtime: false
        )
    }

    private func seconds(of alarm: TripTracker.Alarm) -> Int {
        let instant = ServiceInstant(date: baseDate, seconds: 0).date(in: timeZone)!
        return Int(alarm.fireAt.timeIntervalSince(instant))
    }

    // MARK: - What gets an alarm

    func testAlarmsCoverEveryAlightAndEveryTransferBoarding() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)

        // Two alights, plus boarding the second bus. Boarding the first is not
        // alarmed: the rider is awake and standing at the stop for that one.
        XCTAssertEqual(alarms.count, 3, "got \(alarms.map(\.identifier))")
    }

    func testFirstBoardingIsNotAlarmed() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)
        XCTAssertFalse(
            alarms.contains { $0.identifier.hasSuffix("board.1") },
            "the rider is awake for the first boarding"
        )
    }

    /// The whole promise: exactly one minute of warning, not thirty seconds and
    /// not two minutes.
    func testEachAlarmFiresExactlyOneMinuteEarly() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)

        let firstAlight = try! XCTUnwrap(alarms.first { $0.identifier.hasSuffix("alight.1") })
        XCTAssertEqual(seconds(of: firstAlight), 8 * 3600 + 1_200 - 60)

        let secondBoard = try! XCTUnwrap(alarms.first { $0.identifier.hasSuffix("board.3") })
        XCTAssertEqual(seconds(of: secondBoard), 8 * 3600 + 1_500 - 60)

        let finalAlight = try! XCTUnwrap(alarms.first { $0.identifier.hasSuffix("alight.3") })
        XCTAssertEqual(seconds(of: finalAlight), 8 * 3600 + 2_400 - 60)
    }

    func testAlarmsAreOrderedInTime() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)
        XCTAssertEqual(alarms, alarms.sorted { $0.fireAt < $1.fireAt })
    }

    /// The last alight says something different — "almost there" rather than
    /// "time to get off" — because it ends the journey rather than continuing it.
    func testFinalAlightIsWordedAsArrival() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)
        let final = try! XCTUnwrap(alarms.last)
        XCTAssertTrue(final.identifier.hasSuffix("alight.3"))
        XCTAssertNotEqual(final.title, alarms.first(where: { $0.identifier.hasSuffix("alight.1") })?.title)
    }

    func testAlarmBodyNamesTheStop() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)
        let firstAlight = try! XCTUnwrap(alarms.first { $0.identifier.hasSuffix("alight.1") })
        XCTAssertTrue(firstAlight.body.contains("Stop B"), "got \(firstAlight.body)")
    }

    // MARK: - Edge cases

    /// A walk-only journey has nothing to wake anyone for, and must not schedule
    /// a stray alarm at the destination.
    func testWalkOnlyJourneyHasNoAlarms() {
        let legs = [leg(.walk, from: "Home", to: "Work", depart: 8 * 3600, arrive: 8 * 3600 + 900)]
        let journey = JourneyItem(
            id: "walk", journey: Journey(legs: [], baseDate: baseDate), legs: legs,
            departureSeconds: ServiceSeconds(8 * 3600),
            arrivalSeconds: ServiceSeconds(8 * 3600 + 900),
            baseDate: baseDate, durationSeconds: 900, transferCount: 0,
            walkMeters: 1_000, badges: [], isWalkOnly: true, hasRealtime: false
        )
        XCTAssertTrue(TripTracker.alarms(for: journey, in: timeZone).isEmpty)
    }

    /// A single-ride trip still gets its alight — that is the common case for a
    /// rider who wants to sleep.
    func testSingleRideStillGetsItsAlight() {
        let legs = [
            leg(.ride, from: "A", to: "B", depart: 8 * 3600, arrive: 9 * 3600, line: "480"),
        ]
        let journey = JourneyItem(
            id: "one", journey: Journey(legs: [], baseDate: baseDate), legs: legs,
            departureSeconds: ServiceSeconds(8 * 3600),
            arrivalSeconds: ServiceSeconds(9 * 3600),
            baseDate: baseDate, durationSeconds: 3_600, transferCount: 0,
            walkMeters: 0, badges: [], isWalkOnly: false, hasRealtime: false
        )
        let alarms = TripTracker.alarms(for: journey, in: timeZone)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(seconds(of: alarms[0]), 9 * 3600 - 60)
    }

    /// Identifiers must be unique per trip, or cancelling one trip's alarms
    /// silently cancels another's.
    func testIdentifiersAreUniqueAndTripScoped() {
        let alarms = TripTracker.alarms(for: twoRideJourney(), in: timeZone)
        XCTAssertEqual(Set(alarms.map(\.identifier)).count, alarms.count)
        for alarm in alarms {
            XCTAssertTrue(alarm.identifier.contains("j1"), "got \(alarm.identifier)")
        }
    }

    /// A trip that runs past midnight is expressed in GTFS as the previous day
    /// at 25:xx, and the alarm must land on the following calendar day.
    func testAfterMidnightAlarmLandsOnTheNextDay() {
        let legs = [
            leg(.ride, from: "A", to: "B", depart: 24 * 3600 + 1_800, arrive: 25 * 3600, line: "N1"),
        ]
        let journey = JourneyItem(
            id: "night", journey: Journey(legs: [], baseDate: baseDate), legs: legs,
            departureSeconds: ServiceSeconds(24 * 3600 + 1_800),
            arrivalSeconds: ServiceSeconds(25 * 3600),
            baseDate: baseDate, durationSeconds: 1_800, transferCount: 0,
            walkMeters: 0, badges: [], isWalkOnly: false, hasRealtime: false
        )
        let alarm = TripTracker.alarms(for: journey, in: timeZone).first
        let unwrapped = try! XCTUnwrap(alarm)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.component(.day, from: unwrapped.fireAt)
        XCTAssertEqual(day, 26, "01:00 on the 25th service day is the 26th calendar day")
    }
}
