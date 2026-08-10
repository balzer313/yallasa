import SwiftUI
import MoveItKit

public struct ModeIcon: View {
    private let mode: TransitMode
    private let size: CGFloat

    /// The glyph is sized in points, but a rider who has turned text up to AX5
    /// wants the icons up with it. `@ScaledMetric` keeps the ratio without
    /// pinning a frame, so nothing clips.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    public init(_ mode: TransitMode, size: CGFloat = 16) {
        self.mode = mode
        self.size = size
    }

    public var body: some View {
        Image(systemName: mode.symbolName)
            .font(.system(size: size * scale))
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(mode.displayName)
    }
}

public extension TransitMode {
    /// What a rider calls it. Used for filter chips and as the spoken prefix on
    /// every line badge.
    var displayName: String {
        switch self {
        case .bus: return String(localized: "Bus")
        case .trolleybus: return String(localized: "Trolleybus")
        case .rail: return String(localized: "Train")
        case .subway: return String(localized: "Subway")
        case .tram: return String(localized: "Tram")
        case .cableTram: return String(localized: "Cable tram")
        case .ferry: return String(localized: "Ferry")
        case .monorail: return String(localized: "Monorail")
        case .funicular: return String(localized: "Funicular")
        case .aerialLift: return String(localized: "Cable car")
        case .taxi: return String(localized: "Shared taxi")
        case .other: return String(localized: "Other")
        }
    }
}

#Preview("Modes") {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        ForEach(TransitMode.allCases, id: \.rawValue) { mode in
            HStack(spacing: Theme.Spacing.medium) {
                ModeIcon(mode, size: 20)
                    .foregroundStyle(Theme.Palette.hex(mode.defaultColor))
                Text(mode.displayName)
            }
        }
    }
    .padding()
}
