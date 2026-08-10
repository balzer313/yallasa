import SwiftUI
import MoveItKit

/// One line of a departures board.
///
/// The row is a single VoiceOver element with a composed label. Splitting it into
/// badge / destination / stop / countdown means four swipes to learn one fact,
/// which is how you make a transit app unusable without sight.
public struct DepartureRowView: View {
    private let item: DepartureItem
    private let now: ServiceSeconds
    private let showsStop: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(item: DepartureItem, now: ServiceSeconds, showsStop: Bool = true) {
        self.item = item
        self.now = now
        self.showsStop = showsStop
    }

    private var remaining: Int32 { item.departureSeconds - now }

    public var body: some View {
        // At accessibility sizes a badge, two lines of text and a countdown will
        // not share a row without one of them losing. Stack instead of clipping.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.small))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.medium))

        layout {
            LineBadge(item.badge)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(item.headsign.isEmpty ? String(localized: "Destination unknown") : item.headsign)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if showsStop, !item.stopName.isEmpty {
                    Text(stopLine)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let walkMeters = item.walkMeters {
                    Label(Format.distance(meters: walkMeters), systemImage: "figure.walk")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CountdownLabel(
                seconds: remaining,
                status: item.status,
                showsClock: true,
                clockText: clockText
            )
            .frame(
                maxWidth: dynamicTypeSize.isAccessibilitySize ? CGFloat.infinity : nil,
                alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
            )
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(minHeight: Theme.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The scheduled times are already seconds past midnight of the feed's own
    /// service day, so this needs no timezone conversion — and deliberately does
    /// not take one, because the caller does not always have the feed's zone.
    private var clockText: String {
        ServiceInstant(date: item.queryDate, seconds: item.departureSeconds)
            .normalised
            .seconds
            .clockDescription()
    }

    private var stopLine: String {
        item.stopCode.isEmpty
            ? item.stopName
            : String(localized: "\(item.stopName) · stop \(item.stopCode)")
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.badge.accessibilityLabel]
        if !item.headsign.isEmpty { parts.append(String(localized: "to \(item.headsign)")) }
        if showsStop, !item.stopName.isEmpty { parts.append(String(localized: "from \(item.stopName)")) }
        parts.append(Format.countdownAccessible(seconds: remaining))
        if let shortLabel = item.status.shortLabel { parts.append(shortLabel) }
        if let walkMeters = item.walkMeters {
            parts.append(String(localized: "\(Format.distance(meters: walkMeters)) walk"))
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Rows") {
    ScrollView {
        VStack(spacing: 0) {
            ForEach(PreviewData.departures) { item in
                DepartureRowView(item: item, now: PreviewData.now)
                Divider()
            }
        }
        .padding(.horizontal, Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
}

#Preview("No stop line") {
    VStack(spacing: 0) {
        ForEach(PreviewData.departures.prefix(3)) { item in
            DepartureRowView(item: item, now: PreviewData.now, showsStop: false)
            Divider()
        }
    }
    .padding()
}

#Preview("AX5") {
    ScrollView {
        VStack(spacing: 0) {
            ForEach(PreviewData.departures.prefix(2)) { item in
                DepartureRowView(item: item, now: PreviewData.now)
                Divider()
            }
        }
        .padding(.horizontal, Theme.Spacing.regular)
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Dark") {
    VStack(spacing: 0) {
        ForEach(PreviewData.departures.prefix(3)) { item in
            DepartureRowView(item: item, now: PreviewData.now)
            Divider()
        }
    }
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
