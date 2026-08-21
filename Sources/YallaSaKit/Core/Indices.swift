import Foundation

/// The engine addresses every entity by a dense `Int32` index into a columnar
/// array rather than by its GTFS string id. String ids are kept in a side table
/// for realtime matching and deep links only.
///
/// These are deliberately plain typealiases, not wrapper structs: they are used
/// in the innermost loops of the router, where the optimiser's ability to keep
/// them in registers matters more than nominal type safety.
public typealias StopIndex = Int32
public typealias PatternIndex = Int32
public typealias RouteIndex = Int32
public typealias TripIndex = Int32
public typealias ServiceIndex = Int32
public typealias AgencyIndex = Int32

/// Sentinel used everywhere a "no such entity" index is needed. Chosen as -1 so
/// that an accidental use as an array subscript traps rather than silently
/// reading neighbouring data.
public let noIndex: Int32 = -1

/// Seconds elapsed since noon-minus-12h of the service day, per the GTFS spec.
/// Values >= 86400 are legal and mean "after midnight, still the previous
/// service day" — the 00:35 last bus of a Saturday night is `Saturday, 88500`.
public typealias ServiceSeconds = Int32

/// Sentinel for "this trip does not serve this stop / no time known".
public let noTime: ServiceSeconds = Int32.max

public extension ServiceSeconds {
    /// `25:10:00` → `"01:10"` with a day-rollover marker, for display.
    func clockDescription(includeSeconds: Bool = false) -> String {
        let normalised = ((self % 86_400) + 86_400) % 86_400
        let h = normalised / 3600
        let m = (normalised % 3600) / 60
        let s = normalised % 60
        return includeSeconds
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", h, m)
    }

    /// How many whole service days past the nominal one this time falls into.
    var dayOverflow: Int { Int(self / 86_400) }
}
