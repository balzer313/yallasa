import SwiftUI
import MoveItKit

/// Step-by-step detail for one journey.
///
/// Everything shown here already exists in the `JourneyItem` the planner
/// produced, so the screen needs no engine call to render — which is what lets it
/// appear instantly when a card is tapped. The only live work is the countdown
/// and, when realtime moves, a check that the journey is still catchable.
struct JourneyDetailView: View {
    let item: JourneyItem

    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedLegs: Set<String> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = nowSeconds(at: timeline.date)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    header(now: now)
                    summaryStrip

                    ForEach(item.legs) { leg in
                        legCard(leg, now: now)
                    }

                    footer
                }
                .padding(Theme.Spacing.regular)
            }
        }
        .navigationTitle(Text("Journey"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: textSummary) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("Share this journey"))
            }
        }
    }

    // MARK: - Header

    private func header(now: ServiceSeconds) -> some View {
        let untilDeparture = item.departureSeconds - now
        return SectionCard(title: nil) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if untilDeparture > 0 {
                    Text("Leave in \(Format.countdown(seconds: untilDeparture))")
                        .font(Theme.Typography.countdown(28))
                        .foregroundStyle(Theme.Palette.accent)
                        .accessibilityLabel(Text("Leave \(Format.countdownAccessible(seconds: untilDeparture))"))
                } else if now < item.arrivalSeconds {
                    Text("On the way")
                        .font(Theme.Typography.countdown(28))
                } else {
                    Text("Arrived")
                        .font(Theme.Typography.countdown(28))
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                HStack(spacing: Theme.Spacing.small) {
                    Text(clock(item.departureSeconds))
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(clock(item.arrivalSeconds))
                    Text("·")
                        .accessibilityHidden(true)
                    Text(Format.duration(seconds: item.durationSeconds))
                }
                .font(Theme.Typography.clock)
                .foregroundStyle(Theme.Palette.secondaryText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Text("Departs \(clock(item.departureSeconds)), arrives \(clock(item.arrivalSeconds)), taking \(Format.duration(seconds: item.durationSeconds))")
                )

                HStack(spacing: Theme.Spacing.small) {
                    Text(Format.transferCount(item.transferCount))
                    if item.walkMeters > 0 {
                        Text("·").accessibilityHidden(true)
                        Text(Format.distance(meters: item.walkMeters) + " " + String(localized: "walking"))
                    }
                    if !item.hasRealtime {
                        Text("·").accessibilityHidden(true)
                        Label(String(localized: "Timetable only"), systemImage: "clock")
                            .foregroundStyle(Theme.Palette.scheduled)
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
    }

    /// walk → 42 → walk, at a glance.
    private var summaryStrip: some View {
        FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            ForEach(Array(item.legs.enumerated()), id: \.element.id) { index, leg in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .accessibilityHidden(true)
                }
                switch leg.kind {
                case .walk:
                    Image(systemName: "figure.walk")
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.walk)
                case .ride:
                    if let badge = leg.badge {
                        LineBadge(badge, size: .small)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(textSummary))
    }

    // MARK: - Legs

    @ViewBuilder
    private func legCard(_ leg: JourneyLegItem, now: ServiceSeconds) -> some View {
        switch leg.kind {
        case .walk:
            SectionCard(title: nil) {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(Theme.Palette.walk)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.walkSummary(
                            seconds: leg.arrivalSeconds - leg.departureSeconds,
                            meters: leg.distanceMeters
                        ))
                        .font(Theme.Typography.rowTitle)
                        Text("to \(leg.toName)")
                            .font(Theme.Typography.rowSubtitle)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }

        case .ride:
            SectionCard(title: nil) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        if let badge = leg.badge {
                            LineBadge(badge, size: .regular)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leg.headsign)
                                .font(Theme.Typography.rowTitle)
                            Text("from \(leg.fromName)")
                                .font(Theme.Typography.rowSubtitle)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer(minLength: Theme.Spacing.small)
                        CountdownLabel(
                            seconds: leg.departureSeconds - now,
                            status: leg.status,
                            showsClock: true,
                            clockText: clock(leg.departureSeconds)
                        )
                    }

                    if leg.intermediateStopCount > 0 {
                        Button {
                            toggle(leg.id)
                        } label: {
                            HStack(spacing: Theme.Spacing.tight) {
                                Image(systemName: expandedLegs.contains(leg.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Text(Format.stopCount(leg.intermediateStopCount))
                            }
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.accent)
                        }
                        .buttonStyle(.plain)

                        if expandedLegs.contains(leg.id), !leg.intermediateStopNames.isEmpty {
                            LineDiagram(
                                color: Theme.Palette.hex(leg.badge?.backgroundHex ?? 0x455A64),
                                stops: [leg.fromName] + leg.intermediateStopNames + [leg.toName]
                            )
                        }
                    }

                    Divider()

                    HStack {
                        Text("Get off at \(leg.toName)")
                            .font(Theme.Typography.rowSubtitle)
                        Spacer(minLength: Theme.Spacing.small)
                        Text(clock(leg.arrivalSeconds))
                            .font(Theme.Typography.clock)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }

                    if let stop = leg.toStop {
                        Button {
                            router.show(.stop(stop), in: router.selectedTab)
                        } label: {
                            Text("Stop details")
                                .font(Theme.Typography.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if let updated = service.realtimeUpdatedAt {
                Text("Live times updated \(Format.relativeAge(of: updated))")
            } else {
                Text("Scheduled times. This feed has no live data.")
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Palette.tertiaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func toggle(_ id: String) {
        if expandedLegs.contains(id) {
            expandedLegs.remove(id)
        } else {
            expandedLegs.insert(id)
        }
    }

    private func clock(_ seconds: ServiceSeconds) -> String {
        Format.clock(
            ServiceInstant(date: item.baseDate, seconds: seconds).normalised,
            in: service.timeZone
        )
    }

    private var textSummary: String {
        var parts: [String] = []
        for leg in item.legs {
            switch leg.kind {
            case .walk:
                parts.append(String(localized: "walk to \(leg.toName)"))
            case .ride:
                let name = leg.badge?.text ?? ""
                parts.append(String(localized: "\(name) to \(leg.toName)"))
            }
        }
        return String(
            localized: "\(clock(item.departureSeconds)) → \(clock(item.arrivalSeconds)): "
                + parts.joined(separator: ", ")
        )
    }

    /// The journey's own day frame, so a trip planned for tomorrow counts down
    /// from the right zero.
    private func nowSeconds(at date: Date) -> ServiceSeconds {
        let instant = ServiceInstant(date: date, in: service.timeZone)
        let dayDelta = instant.date.days(since: item.baseDate)
        return instant.seconds + ServiceSeconds(clamping: dayDelta) * 86_400
    }
}
