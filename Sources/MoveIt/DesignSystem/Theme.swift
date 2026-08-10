import SwiftUI
import MoveItKit
#if canImport(UIKit)
// `Color(uiColor:)` needs `UIColor` in scope. SwiftUI usually pulls UIKit in
// transitively, but relying on that breaks the moment this file is compiled in
// a context that does not.
import UIKit
#endif

/// Design tokens.
///
/// Deliberately small. A transit app is read at a walking pace, in sunlight,
/// one-handed, by someone who is late — so the system optimises for legibility
/// and touch target size over decoration. There are two accent colours, one
/// elevation, and no gradients on functional surfaces.
public enum Theme {
    // MARK: Colour

    public enum Palette {
        /// Primary brand accent — used for the active tab, primary buttons and
        /// the "now" marker. Chosen to stay distinguishable from the green and
        /// red that mean "early" and "late" on a departure.
        public static let accent = Color("AccentColor", bundle: .main)

        public static let background = Color(uiColor: .systemGroupedBackground)
        public static let surface = Color(uiColor: .secondarySystemGroupedBackground)
        public static let surfaceRaised = Color(uiColor: .tertiarySystemGroupedBackground)

        public static let primaryText = Color(uiColor: .label)
        public static let secondaryText = Color(uiColor: .secondaryLabel)
        public static let tertiaryText = Color(uiColor: .tertiaryLabel)
        public static let separator = Color(uiColor: .separator)

        /// Realtime status colours. These carry meaning, so every use is paired
        /// with a text or symbol cue — colour alone fails for ~8% of men.
        public static let onTime = Color(red: 0.13, green: 0.60, blue: 0.31)
        public static let late = Color(red: 0.83, green: 0.33, blue: 0.09)
        public static let early = Color(red: 0.16, green: 0.45, blue: 0.78)
        public static let cancelled = Color(red: 0.78, green: 0.16, blue: 0.20)
        /// Scheduled-only, no realtime coverage.
        public static let scheduled = Color(uiColor: .secondaryLabel)

        public static let walk = Color(uiColor: .systemGray)

        /// Converts a GTFS `0xRRGGBB` to a Color.
        public static func hex(_ value: UInt32) -> Color {
            Color(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }

        /// A line's badge colour, darkened just enough in light mode that feed
        /// colours chosen for a white map background stay readable as a fill.
        public static func lineColor(_ value: UInt32) -> Color {
            hex(value)
        }
    }

    // MARK: Spacing

    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let regular: CGFloat = 16
        public static let large: CGFloat = 24
        public static let huge: CGFloat = 32
    }

    public enum Radius {
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 18
        public static let pill: CGFloat = 999
    }

    // MARK: Typography
    //
    // Everything is a Dynamic Type style, never a fixed point size. The one
    // exception is the countdown number, which uses a scaled monospaced digit
    // font so the figures do not jitter as the seconds tick down.

    public enum Typography {
        public static let screenTitle = Font.largeTitle.weight(.bold)
        public static let sectionTitle = Font.title3.weight(.semibold)
        public static let rowTitle = Font.body.weight(.semibold)
        public static let rowSubtitle = Font.subheadline
        public static let caption = Font.caption
        public static let badge = Font.subheadline.weight(.bold)

        public static func countdown(_ size: CGFloat = 22) -> Font {
            .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }

        public static let clock = Font.body.monospacedDigit()
    }

    /// Minimum tappable dimension. Rows that show a countdown are taller, but
    /// nothing interactive is ever smaller than this.
    public static let minimumTouchTarget: CGFloat = 44
}

/// Realtime status of a departure or a leg, and how it should read.
public enum LiveStatus: Equatable, Sendable {
    /// No realtime data covers this trip. Shown as a plain scheduled time —
    /// crucially *not* as "on time", which we do not actually know.
    case scheduled
    case onTime
    case late(seconds: Int32)
    case early(seconds: Int32)
    case cancelled

    public init(delay: Int32?, isCancelled: Bool) {
        if isCancelled {
            self = .cancelled
        } else if let delay {
            // A minute of slop either way is noise in every feed I have seen;
            // reporting "1 min late" from a 40-second delay trains people to
            // ignore the indicator.
            if delay > 60 {
                self = .late(seconds: delay)
            } else if delay < -60 {
                self = .early(seconds: -delay)
            } else {
                self = .onTime
            }
        } else {
            self = .scheduled
        }
    }

    public var color: Color {
        switch self {
        case .scheduled: return Theme.Palette.scheduled
        case .onTime: return Theme.Palette.onTime
        case .late: return Theme.Palette.late
        case .early: return Theme.Palette.early
        case .cancelled: return Theme.Palette.cancelled
        }
    }

    /// Symbol paired with the colour so the meaning survives without it.
    public var symbolName: String? {
        switch self {
        case .scheduled: return "clock"
        case .onTime: return "dot.radiowaves.up.forward"
        case .late: return "exclamationmark.circle"
        case .early: return "arrow.up.circle"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    public var isLive: Bool {
        switch self {
        case .scheduled: return false
        default: return true
        }
    }

    public var shortLabel: String? {
        switch self {
        case .scheduled: return nil
        case .onTime: return String(localized: "On time")
        case .late(let seconds):
            return String(localized: "\(max(1, Int(seconds) / 60)) min late")
        case .early(let seconds):
            return String(localized: "\(max(1, Int(seconds) / 60)) min early")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}
