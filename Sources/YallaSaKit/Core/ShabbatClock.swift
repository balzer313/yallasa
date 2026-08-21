import Foundation

/// Whether a moment falls within Shabbat, and when the next one starts or ends.
///
/// ## Why the engine needs to know
///
/// About 20% of Israel's service patterns run on Saturday — real service, in the
/// Arab sector, around Haifa and Beit Shemesh, and on some intercity routes. The
/// other 80% do not. So on Shabbat the app is correct to show almost nothing in
/// Tel Aviv, and a rider who opens it there on Saturday morning sees an empty
/// board that looks exactly like a failed import.
///
/// The difference between "there is no service" and "something is broken" is the
/// single most useful thing this app can say on a Saturday, and it cannot say it
/// without knowing when Shabbat is.
///
/// ## Why sunset is computed rather than approximated
///
/// A fixed clock time does not work. Sunset in Israel swings from about 16:40 in
/// December to 19:50 in June — more than three hours. A 17:00 cutoff would
/// declare Shabbat on a June Friday while buses are still running everywhere,
/// and miss the start of it entirely in winter.
///
/// ## What it deliberately does not do
///
/// This is **not** a halachic authority and must never be presented as one. It
/// exists to phrase an empty screen, not to tell anyone when to light candles.
/// It uses the common conventions — 18 minutes before sunset, 42 minutes after —
/// and takes no position on the stricter opinions, because nothing here depends
/// on the difference.
public enum ShabbatClock {
    /// Candle lighting: minutes before Friday's sunset.
    public static let startOffsetMinutes: Double = -18
    /// Havdalah: minutes after Saturday's sunset. The common "three stars"
    /// figure; some hold 72, and nothing here turns on which.
    public static let endOffsetMinutes: Double = 42

    /// Israel, near its centre. Sunset varies by only a few minutes across the
    /// country, far less than the offsets above, so one point is enough.
    public static let israel = GeoPoint(latitude: 31.78, longitude: 35.22)

    public static var israelTimeZone: TimeZone {
        TimeZone(identifier: "Asia/Jerusalem") ?? TimeZone(secondsFromGMT: 2 * 3600)!
    }

    /// True when `date` falls between candle lighting and havdalah.
    public static func isShabbat(
        _ date: Date,
        at point: GeoPoint = israel,
        timeZone: TimeZone = israelTimeZone
    ) -> Bool {
        guard let window = window(containing: date, at: point, timeZone: timeZone) else {
            return false
        }
        return date >= window.start && date < window.end
    }

    /// The Shabbat window `date` sits inside, or `nil` when it does not.
    public static func window(
        containing date: Date,
        at point: GeoPoint = israel,
        timeZone: TimeZone = israelTimeZone
    ) -> (start: Date, end: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Check the window that opens today and the one that opened yesterday:
        // a Saturday morning belongs to Friday's window.
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            // 6 = Friday in Gregorian weekday numbering (Sunday == 1).
            guard calendar.component(.weekday, from: day) == 6 else { continue }
            guard let sunsetFriday = sunset(on: day, at: point, timeZone: timeZone),
                  let saturday = calendar.date(byAdding: .day, value: 1, to: day),
                  let sunsetSaturday = sunset(on: saturday, at: point, timeZone: timeZone)
            else { continue }

            let start = sunsetFriday.addingTimeInterval(startOffsetMinutes * 60)
            let end = sunsetSaturday.addingTimeInterval(endOffsetMinutes * 60)
            if date >= start && date < end { return (start, end) }
        }
        return nil
    }

    /// When the Shabbat covering `date` ends. `nil` outside Shabbat.
    public static func endOfShabbat(
        containing date: Date,
        at point: GeoPoint = israel,
        timeZone: TimeZone = israelTimeZone
    ) -> Date? {
        window(containing: date, at: point, timeZone: timeZone)?.end
    }

    // MARK: - Sunset

    /// Local sunset for the calendar day `date` falls on.
    ///
    /// NOAA's solar position algorithm, simplified to the accuracy this needs —
    /// a minute or two, against offsets of 18 and 42 minutes.
    public static func sunset(
        on date: Date,
        at point: GeoPoint = israel,
        timeZone: TimeZone = israelTimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }

        let dayOfYear = Double(dayNumber(year: year, month: month, day: day))
        let longitudeHour = point.longitude / 15

        // Rising/setting differ only in this term; 18 is the setting case.
        let approximateTime = dayOfYear + ((18 - longitudeHour) / 24)

        let meanAnomaly = (0.9856 * approximateTime) - 3.289
        var trueLongitude = meanAnomaly
            + (1.916 * sin(meanAnomaly * .pi / 180))
            + (0.020 * sin(2 * meanAnomaly * .pi / 180))
            + 282.634
        trueLongitude = normalise(trueLongitude, 360)

        var rightAscension = atan(0.91764 * tan(trueLongitude * .pi / 180)) * 180 / .pi
        rightAscension = normalise(rightAscension, 360)
        // Right ascension has to land in the same quadrant as the longitude.
        let longitudeQuadrant = floor(trueLongitude / 90) * 90
        let ascensionQuadrant = floor(rightAscension / 90) * 90
        rightAscension = (rightAscension + (longitudeQuadrant - ascensionQuadrant)) / 15

        let sinDeclination = 0.39782 * sin(trueLongitude * .pi / 180)
        let cosDeclination = cos(asin(sinDeclination))

        // The official zenith for sunset: 90°50′, allowing for refraction and
        // the sun's radius.
        let zenith = 90.833 * .pi / 180
        let cosHourAngle = (cos(zenith) - (sinDeclination * sin(point.latitude * .pi / 180)))
            / (cosDeclination * cos(point.latitude * .pi / 180))
        // No sunset that day — impossible in Israel, but not on a polar feed.
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }

        let hourAngle = (acos(cosHourAngle) * 180 / .pi) / 15
        let localMeanTime = hourAngle + rightAscension - (0.06571 * approximateTime) - 6.622
        let utcHours = normalise(localMeanTime - longitudeHour, 24)

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.hour = Int(utcHours)
        components.minute = Int((utcHours - floor(utcHours)) * 60)
        components.second = 0

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return utcCalendar.date(from: components)
    }

    private static func normalise(_ value: Double, _ range: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: range)
        if result < 0 { result += range }
        return result
    }

    /// Day of the year, 1-based.
    ///
    /// The classic almanac formula. Its `N3` term is usually written as
    /// arithmetic on `year % 4`, which quietly gets 1900 and 2100 wrong; the
    /// full leap rule is written out instead, because it costs nothing.
    private static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let n1 = (275 * month) / 9
        let n2 = (month + 9) / 12
        let n3 = isLeap ? 1 : 2
        return n1 - (n2 * n3) + day - 30
    }
}
