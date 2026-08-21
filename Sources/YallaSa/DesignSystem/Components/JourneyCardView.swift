import SwiftUI
import YallaSaKit

/// A single journey option in the results list.
///
/// Reads top-down as the three things a rider decides on: when do I leave, what
/// do I take, and when do I arrive.
public struct JourneyCardView: View {
    private let item: JourneyItem
    private let now: ServiceSeconds
    private let timeZone: TimeZone

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(item: JourneyItem, now: ServiceSeconds, timeZone: TimeZone) {
        self.item = item
        self.now = now
        self.timeZone = timeZone
    }

    public var body: some View {
        HStack(spacing: 0) {
            // The colour of the first line the rider boards, matching the spine
            // on departure cards and line rows. Three list surfaces, one visual
            // language for "which line is this".
            Rectangle()
                .fill(spineColor)
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                headline
                if !item.badges.isEmpty { badgeStrip }
                summaryLine
            }
            .padding(Theme.Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Palette.separator.opacity(0.5), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A walk-only journey has no line to take its colour from, so it uses the
    /// walking grey rather than defaulting to something that implies a bus.
    private var spineColor: Color {
        guard let badge = item.badges.first else { return Theme.Palette.walk }
        return Theme.Palette.lineColor(badge.backgroundHex)
    }

    private var headline: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.small))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium))

        return layout {
            CountdownLabel(seconds: item.departureSeconds - now, status: departureStatus)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(String(localized: "arrive \(clock(item.arrivalSeconds))"))
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(Format.duration(seconds: item.durationSeconds))
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var badgeStrip: some View {
        FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            ForEach(Array(item.badges.enumerated()), id: \.offset) { index, badge in
                // A chevron between rides makes the sequence read as a route
                // rather than as an unordered set of lines.
                if index > 0 {
                    Image(systemName: "chevron.compact.forward")
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .accessibilityHidden(true)
                }
                LineBadge(badge, size: .small)
            }
        }
    }

    private var summaryLine: some View {
        FlowLayout(spacing: Theme.Spacing.medium, lineSpacing: Theme.Spacing.tight) {
            Label(Format.transferCount(item.transferCount), systemImage: "arrow.triangle.swap")
            if item.walkMeters > 0 {
                Label(Format.distance(meters: item.walkMeters), systemImage: "figure.walk")
            }
            if item.hasRealtime {
                Label(String(localized: "Live"), systemImage: "dot.radiowaves.up.forward")
                    .foregroundStyle(Theme.Palette.onTime)
            }
            if item.isWalkOnly {
                Label(String(localized: "Walk the whole way"), systemImage: "figure.walk.motion")
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Palette.secondaryText)
        .labelStyle(.titleAndIcon)
    }

    /// The first ride's status stands in for the journey: it is the departure the
    /// rider has to make, and the one realtime actually tells us about.
    private var departureStatus: LiveStatus {
        item.legs.first(where: { $0.kind == .ride })?.status ?? .scheduled
    }

    private func clock(_ seconds: ServiceSeconds) -> String {
        Format.clock(ServiceInstant(date: item.baseDate, seconds: seconds).normalised, in: timeZone)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            String(localized: "Leaves \(Format.countdownAccessible(seconds: item.departureSeconds - now))"),
            String(localized: "arrives \(clock(item.arrivalSeconds))"),
            String(localized: "takes \(Format.duration(seconds: item.durationSeconds))")
        ]
        if item.isWalkOnly {
            parts.append(String(localized: "on foot the whole way"))
        } else if !item.badges.isEmpty {
            parts.append(
                String(localized: "via \(item.badges.map(\.accessibilityLabel).joined(separator: ", then "))")
            )
        }
        parts.append(Format.transferCount(item.transferCount))
        if item.walkMeters > 0 {
            parts.append(String(localized: "\(Format.distance(meters: item.walkMeters)) of walking"))
        }
        if let shortLabel = departureStatus.shortLabel { parts.append(shortLabel) }
        return parts.joined(separator: ", ")
    }
}

#Preview("Journey") {
    ScrollView {
        VStack(spacing: Theme.Spacing.medium) {
            JourneyCardView(item: PreviewData.journeyItem, now: PreviewData.now, timeZone: .current)
            JourneyCardView(
                item: walkOnly,
                now: PreviewData.now,
                timeZone: .current
            )
        }
        .padding(Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
}

#Preview("Dark, AX5") {
    ScrollView {
        JourneyCardView(item: PreviewData.journeyItem, now: PreviewData.now, timeZone: .current)
            .padding(Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}

private var walkOnly: JourneyItem {
    var item = PreviewData.journeyItem
    item.badges = []
    item.isWalkOnly = true
    item.hasRealtime = false
    item.transferCount = 0
    item.walkMeters = 1_240
    item.durationSeconds = 980
    return item
}
