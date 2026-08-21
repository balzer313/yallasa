import Foundation

/// The transport modes the UI actually distinguishes. GTFS defines a basic set
/// (0–12) plus several hundred extended codes (100–1700); both collapse into
/// this enum, because a rider cares that it is "a train" and not that the feed
/// called it a `106 Regional Rail Service`.
public enum TransitMode: UInt8, Hashable, Sendable, Codable, CaseIterable {
    case tram = 0
    case subway = 1
    case rail = 2
    case bus = 3
    case ferry = 4
    case cableTram = 5
    case aerialLift = 6
    case funicular = 7
    case trolleybus = 11
    case monorail = 12
    case taxi = 13
    case other = 255

    /// Maps any GTFS `route_type` — the basic 0–12 set or the extended
    /// (Hierarchical Vehicle Type) codes — onto a mode.
    ///
    /// Cases are ordered most-specific-first because Swift takes the first
    /// match: `405` is Monorail and must be caught before the `400...405`
    /// Urban Railway range, and `800` is Trolleybus before the coach/bus ranges.
    public init(gtfsRouteType value: Int) {
        switch value {
        // Basic types.
        case 0: self = .tram
        case 1: self = .subway
        case 2: self = .rail
        case 3: self = .bus
        case 4: self = .ferry
        case 5: self = .cableTram
        case 6: self = .aerialLift
        case 7: self = .funicular
        case 11: self = .trolleybus
        case 12: self = .monorail

        // Extended types, specific codes before the ranges that contain them.
        case 405: self = .monorail
        case 800: self = .trolleybus
        case 100...199, 300...399: self = .rail
        case 200...299: self = .bus
        case 400...404: self = .subway
        case 700...799: self = .bus
        case 900...999: self = .tram
        case 1000...1099, 1200...1299: self = .ferry
        case 1300...1399: self = .aerialLift
        case 1400...1499: self = .funicular
        case 1500...1599: self = .taxi

        default: self = .other
        }
    }

    /// SF Symbol name for the mode. Every one of these ships with iOS 17.
    public var symbolName: String {
        switch self {
        case .tram, .cableTram: return "tram.fill"
        case .subway: return "tram.tunnel.fill"
        case .rail: return "train.side.front.car"
        case .bus, .trolleybus: return "bus.fill"
        case .ferry: return "ferry.fill"
        case .aerialLift: return "cablecar.fill"
        case .funicular: return "cablecar"
        case .monorail: return "tram.fill"
        case .taxi: return "car.fill"
        case .other: return "arrow.triangle.turn.up.right.diamond.fill"
        }
    }

    /// Fallback brand colour, used when the feed supplies no `route_color`.
    /// Hex is `0xRRGGBB`.
    public var defaultColor: UInt32 {
        switch self {
        case .tram, .cableTram: return 0x00796B
        case .subway: return 0x1565C0
        case .rail: return 0x6A1B9A
        case .bus, .trolleybus: return 0x2E7D32
        case .ferry: return 0x0277BD
        case .aerialLift, .funicular: return 0xEF6C00
        case .monorail: return 0x4527A0
        case .taxi: return 0xF9A825
        case .other: return 0x455A64
        }
    }

    /// Used for sorting a departures board so that the rail options — which are
    /// usually the backbone of a trip — sit above the buses.
    public var displayPriority: Int {
        switch self {
        case .rail: return 0
        case .subway: return 1
        case .tram, .cableTram, .monorail: return 2
        case .ferry: return 3
        case .bus, .trolleybus: return 4
        case .aerialLift, .funicular: return 5
        case .taxi, .other: return 6
        }
    }

    public var localizedNameKey: String { "mode.\(self)" }
}

/// GTFS `pickup_type` / `drop_off_type`. Only `.regular` and `.phoneAgency`-style
/// values matter to the router: anything that is not regularly available is
/// treated as "cannot board/alight here" so the planner never invents a boarding
/// at a stop the bus only passes through.
public enum StopServiceAvailability: UInt8, Hashable, Sendable {
    case regular = 0
    case none = 1
    case phoneAgency = 2
    case coordinateWithDriver = 3

    public init(gtfs value: Int) {
        self = StopServiceAvailability(rawValue: UInt8(clamping: value)) ?? .regular
    }

    /// Whether the router may use this as a boarding or alighting point.
    public var isRoutable: Bool { self == .regular }
}

/// GTFS `wheelchair_accessible` / `wheelchair_boarding` tri-state.
public enum AccessibilityFlag: UInt8, Hashable, Sendable, Codable {
    case unknown = 0
    case accessible = 1
    case notAccessible = 2

    public init(gtfs value: Int) {
        self = AccessibilityFlag(rawValue: UInt8(clamping: value)) ?? .unknown
    }
}
