import XCTest
@testable import YallaSaKit

final class ServiceCalendarBuilderTests: XCTestCase {

    // 2026-01-01 is a Thursday, which every fixture below leans on.
    private let january = ServiceDate(year: 2026, month: 1, day: 1)

    private func date(_ day: Int) -> ServiceDate {
        ServiceDate(year: 2026, month: 1, day: day)
    }

    private func isActive(_ result: ServiceCalendarBuilder.Result, service: Int, on date: ServiceDate) -> Bool {
        let day = date.days(since: result.calendarStart)
        guard day >= 0, day < result.calendarDayCount, result.bitsetStride > 0 else { return false }
        let byteIndex = service * result.bitsetStride + (day >> 3)
        guard byteIndex < result.bits.count else { return false }
        let mask: UInt8 = 1 << UInt8(day & 7)
        return result.bits[byteIndex] & mask != 0
    }

    func testWeekdayMaskExpandsAcrossTheRange() {
        let weekdays = GTFSCalendarRow(
            serviceRef: 1,
            weekdayMask: 0b0011111, // Monday…Friday
            startDate: date(1),
            endDate: date(31)
        )
        let result = ServiceCalendarBuilder.build(calendars: [weekdays], exceptions: [], window: nil)

        XCTAssertEqual(result.calendarStart, january)
        XCTAssertEqual(result.calendarDayCount, 31)
        XCTAssertEqual(result.bitsetStride, 4)
        XCTAssertEqual(result.identifierRefs, [1])

        XCTAssertTrue(isActive(result, service: 0, on: date(1)), "Thursday 1 January runs")
        XCTAssertTrue(isActive(result, service: 0, on: date(2)), "Friday 2 January runs")
        XCTAssertFalse(isActive(result, service: 0, on: date(3)), "Saturday 3 January does not")
        XCTAssertFalse(isActive(result, service: 0, on: date(4)), "Sunday 4 January does not")
        XCTAssertTrue(isActive(result, service: 0, on: date(5)), "Monday 5 January runs")
        XCTAssertTrue(isActive(result, service: 0, on: date(30)), "The last Friday in range runs")
    }

    func testAddedExceptionCreatesServiceWithNoCalendarRow() {
        let added = GTFSCalendarDateRow(serviceRef: 7, date: date(3), isAdded: true)
        let result = ServiceCalendarBuilder.build(calendars: [], exceptions: [added], window: nil)

        XCTAssertEqual(result.calendarStart, date(3))
        XCTAssertEqual(result.calendarDayCount, 1)
        XCTAssertEqual(result.identifierRefs, [7])
        XCTAssertTrue(isActive(result, service: 0, on: date(3)))
    }

    func testRemovedExceptionClearsADayTheMaskSet() {
        let weekdays = GTFSCalendarRow(
            serviceRef: 1,
            weekdayMask: 0b0011111,
            startDate: date(1),
            endDate: date(31)
        )
        let removed = GTFSCalendarDateRow(serviceRef: 1, date: date(5), isAdded: false)
        let result = ServiceCalendarBuilder.build(calendars: [weekdays], exceptions: [removed], window: nil)

        XCTAssertFalse(isActive(result, service: 0, on: date(5)), "Monday 5 January was removed")
        XCTAssertTrue(isActive(result, service: 0, on: date(6)), "Tuesday 6 January is untouched")
    }

    func testRemovalWinsRegardlessOfFileOrder() {
        // A feed that lists the removal before the calendar row must still lose
        // the day; the builder applies exceptions after every weekday mask.
        let weekdays = GTFSCalendarRow(
            serviceRef: 1,
            weekdayMask: 0b1111111,
            startDate: date(1),
            endDate: date(7)
        )
        let removed = GTFSCalendarDateRow(serviceRef: 1, date: date(4), isAdded: false)
        let result = ServiceCalendarBuilder.build(calendars: [weekdays], exceptions: [removed], window: nil)

        XCTAssertFalse(isActive(result, service: 0, on: date(4)))
        XCTAssertTrue(isActive(result, service: 0, on: date(3)))
    }

    func testServiceWithNoActiveDayIsDropped() {
        let empty = GTFSCalendarRow(serviceRef: 5, weekdayMask: 0, startDate: date(1), endDate: date(31))
        let live = GTFSCalendarRow(serviceRef: 6, weekdayMask: 0b1000000, startDate: date(1), endDate: date(31))
        let result = ServiceCalendarBuilder.build(calendars: [empty, live], exceptions: [], window: nil)

        XCTAssertEqual(result.droppedEmptyServices, 1)
        XCTAssertEqual(result.identifierRefs, [6])
        XCTAssertNil(result.indexByServiceRef[5])
        XCTAssertEqual(result.indexByServiceRef[6], 0)
        XCTAssertEqual(result.bits.count, result.bitsetStride)
    }

    func testWindowClampsBothEnds() {
        let wide = GTFSCalendarRow(
            serviceRef: 1,
            weekdayMask: 0b1111111,
            startDate: ServiceDate(year: 2026, month: 1, day: 1),
            endDate: ServiceDate(year: 2026, month: 12, day: 31)
        )
        let window = ServiceDate(year: 2026, month: 2, day: 1)...ServiceDate(year: 2026, month: 2, day: 10)
        let result = ServiceCalendarBuilder.build(calendars: [wide], exceptions: [], window: window)

        XCTAssertEqual(result.calendarStart, ServiceDate(year: 2026, month: 2, day: 1))
        XCTAssertEqual(result.calendarDayCount, 10)
        XCTAssertEqual(result.bitsetStride, 2)
        XCTAssertTrue(isActive(result, service: 0, on: ServiceDate(year: 2026, month: 2, day: 10)))
        XCTAssertFalse(isActive(result, service: 0, on: ServiceDate(year: 2026, month: 2, day: 11)))
    }

    func testRangeIsCappedAtFourHundredDays() {
        let decade = GTFSCalendarRow(
            serviceRef: 1,
            weekdayMask: 0b1111111,
            startDate: ServiceDate(year: 2026, month: 1, day: 1),
            endDate: ServiceDate(year: 2036, month: 1, day: 1)
        )
        let result = ServiceCalendarBuilder.build(calendars: [decade], exceptions: [], window: nil)

        XCTAssertEqual(result.calendarDayCount, ServiceCalendarBuilder.maximumDayCount)
        XCTAssertEqual(result.bitsetStride, (ServiceCalendarBuilder.maximumDayCount + 7) / 8)
    }

    func testRemovalOutsideTheFeedRangeDoesNotWidenIt() {
        let week = GTFSCalendarRow(
            serviceRef: 1,
            weekdayMask: 0b1111111,
            startDate: date(1),
            endDate: date(7)
        )
        let stray = GTFSCalendarDateRow(
            serviceRef: 1,
            date: ServiceDate(year: 2030, month: 1, day: 1),
            isAdded: false
        )
        let result = ServiceCalendarBuilder.build(calendars: [week], exceptions: [stray], window: nil)

        XCTAssertEqual(result.calendarStart, january)
        XCTAssertEqual(result.calendarDayCount, 7)
    }
}
