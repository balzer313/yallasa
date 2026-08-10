import SwiftUI
import MoveItKit

/// The big "3 min" with its live/scheduled treatment.
///
/// Three things are load-bearing here. The digits are monospaced so the number
/// does not jitter as it ticks. A live time is marked with both a colour and a
/// symbol, because colour alone fails for roughly one man in twelve. And a
/// scheduled time is never dressed up as "on time" — we do not know that.
public struct CountdownLabel: View {
    private let seconds: Int32
    private let status: LiveStatus
    private let showsClock: Bool
    private let clockText: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

    public init(
        seconds: Int32,
        status: LiveStatus,
        showsClock: Bool = false,
        clockText: String? = nil
    ) {
        self.seconds = seconds
        self.status = status
        self.showsClock = showsClock
        self.clockText = clockText
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.hairline) {
            HStack(spacing: Theme.Spacing.tight) {
                if status.isLive, let symbolName = status.symbolName {
                    Image(systemName: symbolName)
                        .font(.caption)
                        .imageScale(.small)
                }
                Text(Format.countdown(seconds: seconds))
                    .font(Theme.Typography.countdown())
                    .strikethrough(isCancelled, color: Theme.Palette.cancelled)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .default, value: seconds)
            }
            .foregroundStyle(numberColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if let detail = detailText {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(status.isLive ? status.color : Theme.Palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        // A floor, not a fixed size: keeps a column of countdowns aligned without
        // clipping "1 hr 12 min" at AX5.
        .frame(minWidth: 62 * scale, alignment: .trailing)
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isCancelled: Bool {
        if case .cancelled = status { return true }
        return false
    }

    private var numberColor: Color {
        switch status {
        // A scheduled time is still the primary information on the row, so it
        // keeps full contrast; only its *annotation* is muted.
        case .scheduled: return Theme.Palette.primaryText
        default: return status.color
        }
    }

    private var detailText: String? {
        if let shortLabel = status.shortLabel, status.isLive, !isOnTimeWithClock {
            return shortLabel
        }
        if showsClock, let clockText { return clockText }
        return nil
    }

    /// When the row already shows a clock time, "On time" and the clock compete
    /// for the same line; the clock wins because it answers a different question.
    private var isOnTimeWithClock: Bool {
        if case .onTime = status { return showsClock && clockText != nil }
        return false
    }

    private var accessibilityLabel: String {
        var parts: [String] = [Format.countdownAccessible(seconds: seconds)]
        if let shortLabel = status.shortLabel { parts.append(shortLabel) }
        if showsClock, let clockText { parts.append(String(localized: "at \(clockText)")) }
        // Comma-joined fragments, each independently localised: VoiceOver reads
        // the pause as a beat, and no sentence is assembled by concatenation.
        return parts.joined(separator: ", ")
    }
}

#Preview("Statuses") {
    VStack(alignment: .trailing, spacing: Theme.Spacing.large) {
        CountdownLabel(seconds: 30, status: .onTime, showsClock: true, clockText: "08:01")
        CountdownLabel(seconds: 260, status: .late(seconds: 210), showsClock: true, clockText: "08:05")
        CountdownLabel(seconds: 720, status: .scheduled, showsClock: true, clockText: "08:12")
        CountdownLabel(seconds: 1_980, status: .early(seconds: 90))
        CountdownLabel(seconds: 4_500, status: .cancelled)
        CountdownLabel(seconds: -30, status: .scheduled)
    }
    .padding()
    .background(Theme.Palette.background)
}

#Preview("AX5") {
    CountdownLabel(seconds: 4_500, status: .late(seconds: 300), showsClock: true, clockText: "09:15")
        .padding()
        .environment(\.dynamicTypeSize, .accessibility5)
}
