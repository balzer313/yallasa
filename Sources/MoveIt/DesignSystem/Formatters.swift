import Foundation
import MoveItKit

/// Every user-visible number in the app is formatted here.
///
/// Centralised for two reasons that both bit me in earlier transit UIs: a clock
/// time must be rendered in the *feed's* timezone rather than the device's (a
/// rider checking Tel Aviv buses from London wants Israeli times), and a
/// countdown must round the way a person reads a clock, not the way `Int`
/// division does.
public enum Format {
    // MARK: - Countdowns

    /// The big number on a departure row.
    ///
    /// Rounds up, because "2 min" that is really 2:50 and shows as 2 sends
    /// people out the door too late. Under a minute reads as "now" — a rider at
    /// the stop does not need the seconds, they need to look up.
    public static func countdown(seconds: Int32) -> String {
        if seconds < 0 { return String(localized: "departed") }
        if seconds < 60 { return String(localized: "now") }
        let minutes = Int((seconds + 59) / 60)
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return String(localized: "\(hours) hr") }
        return String(localized: "\(hours) hr \(remainder) min")
    }

    /// Accessibility phrasing for the same value. VoiceOver reading "3 min"
    /// as "three em eye en" is the kind of detail that decides whether a blind
    /// rider can use the app at all.
    public static func countdownAccessible(seconds: Int32) -> String {
        if seconds < 0 { return String(localized: "already departed") }
        if seconds < 60 { return String(localized: "departing now") }
        let minutes = Int((seconds + 59) / 60)
        if minutes < 60 {
            return String(localized: "in \(minutes) minutes")
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return String(localized: "in \(hours) hours") }
        return String(localized: "in \(hours) hours \(remainder) minutes")
    }

    /// A journey duration, e.g. "1 hr 12 min".
    public static func duration(seconds: Int32) -> String {
        let minutes = max(0, Int((seconds + 30) / 60))
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return String(localized: "\(hours) hr") }
        return String(localized: "\(hours) hr \(remainder) min")
    }

    // MARK: - Clock times

    private static var clockFormatters: [String: DateFormatter] = [:]

    /// Wall-clock time in the feed's timezone.
    public static func clock(_ instant: ServiceInstant, in timeZone: TimeZone) -> String {
        guard let date = instant.date(in: timeZone) else {
            return instant.seconds.clockDescription()
        }
        return clock(date, in: timeZone)
    }

    public static func clock(_ date: Date, in timeZone: TimeZone) -> String {
        formatter(for: timeZone, template: "jm").string(from: date)
    }

    public static func clockWithDay(_ date: Date, in timeZone: TimeZone) -> String {
        formatter(for: timeZone, template: "EEE jm").string(from: date)
    }

    public static func dayAndDate(_ date: Date, in timeZone: TimeZone) -> String {
        formatter(for: timeZone, template: "EEEE d MMMM").string(from: date)
    }

    private static func formatter(for timeZone: TimeZone, template: String) -> DateFormatter {
        let key = "\(timeZone.identifier)|\(template)"
        if let existing = clockFormatters[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        clockFormatters[key] = formatter
        return formatter
    }

    /// True when the feed's timezone differs from the device's, which is when the
    /// UI should start labelling times with the zone to avoid confusion.
    public static func needsTimeZoneLabel(_ timeZone: TimeZone, at date: Date = Date()) -> Bool {
        timeZone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date)
    }

    // MARK: - Distance

    public static func distance(meters: Double) -> String {
        let usesMetric = Locale.current.measurementSystem != .us
        if usesMetric {
            if meters < 950 { return String(localized: "\(Int((meters / 10).rounded()) * 10) m") }
            let kilometres = meters / 1000
            return String(localized: "\(kilometres.formatted(.number.precision(.fractionLength(kilometres < 10 ? 1 : 0)))) km")
        } else {
            let feet = meters * 3.28084
            if feet < 1000 { return String(localized: "\(Int((feet / 10).rounded()) * 10) ft") }
            let miles = meters / 1609.344
            return String(localized: "\(miles.formatted(.number.precision(.fractionLength(miles < 10 ? 1 : 0)))) mi")
        }
    }

    /// "4 min walk · 320 m"
    public static func walkSummary(seconds: Int32, meters: Double) -> String {
        String(localized: "\(duration(seconds: seconds)) walk · \(distance(meters: meters))")
    }

    // MARK: - Journey summary

    /// "3 stops" / "1 stop"
    public static func stopCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 stop") : String(localized: "\(count) stops")
    }

    public static func transferCount(_ count: Int) -> String {
        switch count {
        case 0: return String(localized: "Direct")
        case 1: return String(localized: "1 transfer")
        default: return String(localized: "\(count) transfers")
        }
    }

    /// How long ago a realtime snapshot was generated, for the freshness label.
    public static func relativeAge(of date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 15 { return String(localized: "just now") }
        if seconds < 60 { return String(localized: "\(seconds)s ago") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes) min ago") }
        return String(localized: "\(minutes / 60) hr ago")
    }

    public static func fileSize(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
