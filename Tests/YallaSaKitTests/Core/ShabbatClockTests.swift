import XCTest
@testable import YallaSaKit

/// These assert *properties* rather than minute-exact sunset times.
///
/// Pinning "sunset on 21 August is 19:22" would be asserting against a number
/// this suite cannot independently verify, and the offsets it feeds — 18 and 42
/// minutes — are far larger than the algorithm's error anyway. What matters is
/// that sunset moves the right way through the year, lands in a plausible band
/// for Israel, and that the window it defines starts and ends on the right days.
final class ShabbatClockTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ShabbatClock.israelTimeZone
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    private func localHour(_ date: Date) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour!) + Double(c.minute!) / 60
    }

    // MARK: - Sunset

    func testSunsetIsLaterInSummerThanInWinter() throws {
        let june = try XCTUnwrap(ShabbatClock.sunset(on: date(2026, 6, 21, 12)))
        let december = try XCTUnwrap(ShabbatClock.sunset(on: date(2026, 12, 21, 12)))
        XCTAssertGreaterThan(localHour(june), localHour(december) + 2,
                             "Israeli sunset swings roughly three hours across the year")
    }

    func testSunsetFallsInAPlausibleBandForIsrael() throws {
        // Across a whole year, no Israeli sunset is before 16:30 or after 20:00
        // local — and if the algorithm is broken it lands nowhere near.
        for month in 1...12 {
            let sunset = try XCTUnwrap(ShabbatClock.sunset(on: date(2026, month, 15, 12)))
            let hour = localHour(sunset)
            XCTAssertGreaterThan(hour, 16.3, "month \(month) sunset at \(hour)")
            XCTAssertLessThan(hour, 20.1, "month \(month) sunset at \(hour)")
        }
    }

    /// August sunset in Israel is a little after seven. This is the loosest
    /// useful pin: wrong by an hour and it fails, wrong by two minutes and it
    /// does not.
    func testAugustSunsetIsJustAfterSeven() throws {
        let sunset = try XCTUnwrap(ShabbatClock.sunset(on: date(2026, 8, 21, 12)))
        let hour = localHour(sunset)
        XCTAssertGreaterThan(hour, 18.75, "got \(hour)")
        XCTAssertLessThan(hour, 19.75, "got \(hour)")
    }

    // MARK: - The window

    func testSaturdayMiddayIsShabbat() {
        // 22 August 2026 is a Saturday.
        XCTAssertTrue(ShabbatClock.isShabbat(date(2026, 8, 22, 12)))
    }

    func testWednesdayMiddayIsNot() {
        XCTAssertFalse(ShabbatClock.isShabbat(date(2026, 8, 19, 12)))
    }

    func testFridayMorningIsNotYetShabbat() {
        XCTAssertFalse(ShabbatClock.isShabbat(date(2026, 8, 21, 9)),
                       "buses run normally on a Friday morning")
    }

    func testFridayNightIsShabbat() {
        // Well after any August sunset.
        XCTAssertTrue(ShabbatClock.isShabbat(date(2026, 8, 21, 21)))
    }

    func testSaturdayLateEveningIsAfterHavdalah() {
        // Sunset ~19:20 plus 42 minutes puts havdalah near 20:02.
        XCTAssertFalse(ShabbatClock.isShabbat(date(2026, 8, 22, 23)),
                       "service resumes on Saturday night")
    }

    func testWindowRunsFromFridayEveningToSaturdayEvening() throws {
        let window = try XCTUnwrap(ShabbatClock.window(containing: date(2026, 8, 22, 12)))

        XCTAssertEqual(calendar.component(.weekday, from: window.start), 6, "starts on a Friday")
        XCTAssertEqual(calendar.component(.weekday, from: window.end), 7, "ends on a Saturday")

        let hours = window.end.timeIntervalSince(window.start) / 3600
        XCTAssertGreaterThan(hours, 24.5, "a Shabbat is about 25 hours, got \(hours)")
        XCTAssertLessThan(hours, 25.5, "a Shabbat is about 25 hours, got \(hours)")
    }

    func testWindowIsNilMidweek() {
        XCTAssertNil(ShabbatClock.window(containing: date(2026, 8, 19, 12)))
    }

    func testEndOfShabbatIsAfterTheMomentAsked() throws {
        let noonSaturday = date(2026, 8, 22, 12)
        let end = try XCTUnwrap(ShabbatClock.endOfShabbat(containing: noonSaturday))
        XCTAssertGreaterThan(end, noonSaturday)
        XCTAssertEqual(calendar.component(.weekday, from: end), 7)
    }

    /// Winter Shabbat starts far earlier than summer Shabbat. A fixed clock-time
    /// implementation passes every test above and fails this one, which is why
    /// sunset is computed rather than approximated.
    func testWinterShabbatStartsMuchEarlierThanSummer() throws {
        let summer = try XCTUnwrap(ShabbatClock.window(containing: date(2026, 6, 20, 12)))
        let winter = try XCTUnwrap(ShabbatClock.window(containing: date(2026, 12, 19, 12)))
        XCTAssertGreaterThan(
            localHour(summer.start), localHour(winter.start) + 2,
            "a fixed cutoff would make these equal"
        )
    }

    func testFridayAfternoonInWinterIsAlreadyShabbat() {
        // 16:50 on a December Friday is after sunset; the same clock time in
        // June is broad daylight.
        XCTAssertTrue(ShabbatClock.isShabbat(date(2026, 12, 18, 17)))
        XCTAssertFalse(ShabbatClock.isShabbat(date(2026, 6, 19, 17)))
    }
}
