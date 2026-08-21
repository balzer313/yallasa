import Foundation

/// A calendar date in the feed's own timezone, with no time component.
///
/// GTFS service days are civil dates, not instants, and a "day" can be 23 or 25
/// hours long across a DST boundary. Doing arithmetic in `Date` invites exactly
/// the class of off-by-one-hour bug that makes a planner tell you to catch a bus
/// that left an hour ago, so the engine works in `ServiceDate` + seconds-past-
/// midnight and only converts to `Date` at the display boundary.
public struct ServiceDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses the GTFS `YYYYMMDD` form. Returns nil for anything else.
    public init?(gtfs: some StringProtocol) {
        guard gtfs.count == 8 else { return nil }
        var value = 0
        for character in gtfs.utf8 {
            guard character >= 48, character <= 57 else { return nil }
            value = value * 10 + Int(character - 48)
        }
        let year = value / 10_000
        let month = (value / 100) % 100
        let day = value % 100
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var gtfsString: String {
        String(format: "%04d%02d%02d", year, month, day)
    }

    public var description: String { gtfsString }

    public static func < (lhs: ServiceDate, rhs: ServiceDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: - Day arithmetic
    //
    // Howard Hinnant's civil-from-days / days-from-civil. Branch-free, exact for
    // any proleptic Gregorian date, and — unlike Calendar — free of timezone,
    // locale and DST behaviour, which is precisely what we want for service days.

    /// Days since 1970-01-01.
    public var epochDay: Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(epochDay: Int) {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: y + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    public func adding(days: Int) -> ServiceDate {
        ServiceDate(epochDay: epochDay + days)
    }

    public func days(since other: ServiceDate) -> Int {
        epochDay - other.epochDay
    }

    /// 0 = Monday … 6 = Sunday, matching the column order of `calendar.txt`.
    public var weekdayIndex: Int {
        let value = (epochDay + 3) % 7
        return value < 0 ? value + 7 : value
    }

    // MARK: - Bridging to Foundation

    /// The instant of midnight at the start of this service day, in `timeZone`.
    public func startOfDay(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The service date that `date` falls on in `timeZone`.
    public init(date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }
}

/// A moment expressed the way the router thinks about it: which service day, and
/// how many seconds past that day's midnight.
public struct ServiceInstant: Hashable, Sendable {
    public var date: ServiceDate
    public var seconds: ServiceSeconds

    public init(date: ServiceDate, seconds: ServiceSeconds) {
        self.date = date
        self.seconds = seconds
    }

    /// Splits a wall-clock instant. Seconds are measured from local midnight, so
    /// on a spring-forward day 03:00 local is 7200s, not 10800s — which is right,
    /// because the buses that day really do run on a 23-hour clock.
    public init(date instant: Date, in timeZone: TimeZone) {
        let day = ServiceDate(date: instant, in: timeZone)
        let midnight = day.startOfDay(in: timeZone) ?? instant
        self.date = day
        self.seconds = ServiceSeconds(instant.timeIntervalSince(midnight).rounded())
    }

    /// Back to a wall-clock instant, folding any day overflow into the date.
    public func date(in timeZone: TimeZone) -> Date? {
        guard let midnight = date.startOfDay(in: timeZone) else { return nil }
        return midnight.addingTimeInterval(TimeInterval(seconds))
    }

    /// Normalises so that `seconds` lands in `0..<86400`, moving whole days into
    /// `date`. Note this is a nominal 86400-second day: correct for comparing
    /// against GTFS times, which are themselves defined against noon-minus-12h.
    public var normalised: ServiceInstant {
        var days = Int(seconds) / 86_400
        var remainder = Int(seconds) % 86_400
        if remainder < 0 {
            remainder += 86_400
            days -= 1
        }
        return ServiceInstant(date: date.adding(days: days), seconds: ServiceSeconds(remainder))
    }
}

/// Parses the GTFS `H:MM:SS` / `HH:MM:SS` time form, which may exceed 24 hours.
/// Returns nil rather than throwing: a malformed time in one row of a 40-million
/// row `stop_times.txt` should drop that row, not the feed.
@inlinable
public func parseGTFSTime(_ text: some StringProtocol) -> ServiceSeconds? {
    var digits = 0
    var field = 0
    var fields: (Int, Int, Int) = (0, 0, 0)
    var index = 0
    for character in text.utf8 {
        if character == UInt8(ascii: ":") {
            guard digits > 0, field < 2 else { return nil }
            switch field {
            case 0: fields.0 = index
            case 1: fields.1 = index
            default: return nil
            }
            field += 1
            digits = 0
            index = 0
        } else if character >= 48, character <= 57 {
            index = index * 10 + Int(character - 48)
            digits += 1
            if digits > 3 { return nil }
        } else if character == UInt8(ascii: " ") {
            continue
        } else {
            return nil
        }
    }
    guard field == 2, digits > 0 else { return nil }
    fields.2 = index
    guard fields.1 < 60, fields.2 < 60, fields.0 < 240 else { return nil }
    return ServiceSeconds(fields.0 * 3600 + fields.1 * 60 + fields.2)
}
