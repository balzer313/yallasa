import SwiftUI
import YallaSaKit

// MARK: - Mode filter

/// A row of mode chips. Filtering is client-side, so tapping one is instant —
/// which is the entire reason it exists as chips rather than as a menu.
struct ModeFilterBar: View {
    let modes: [TransitMode]
    @Binding var selection: Set<TransitMode>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                chip(
                    title: String(localized: "All"),
                    systemImage: nil,
                    isOn: selection.isEmpty,
                    accessibilityLabel: String(localized: "All modes")
                ) {
                    selection.removeAll()
                }

                ForEach(modes, id: \.rawValue) { mode in
                    chip(
                        title: mode.displayName,
                        systemImage: mode.symbolName,
                        isOn: selection.contains(mode),
                        accessibilityLabel: mode.displayName
                    ) {
                        if selection.contains(mode) {
                            selection.remove(mode)
                        } else {
                            selection.insert(mode)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.regular)
            .padding(.vertical, Theme.Spacing.tight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Filter by mode"))
    }

    @ViewBuilder
    private func chip(
        title: String,
        systemImage: String?,
        isOn: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(Theme.Typography.rowSubtitle.weight(isOn ? .semibold : .regular))
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .frame(minHeight: Theme.minimumTouchTarget - Theme.Spacing.medium)
            .foregroundStyle(isOn ? Color.white : Theme.Palette.primaryText)
            .background(
                Capsule().fill(isOn ? Theme.Palette.accent : Theme.Palette.surface)
            )
            .overlay(
                Capsule().strokeBorder(
                    isOn ? Color.clear : Theme.Palette.separator,
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        // Selection is spoken, not just tinted — the fill alone is invisible to
        // VoiceOver and ambiguous in bright sunlight.
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Alerts

struct AlertsBanner: View {
    let alerts: [ServiceAlert]
    let action: () -> Void

    private var headline: ServiceAlert? {
        alerts.max { $0.severity < $1.severity }
    }

    var body: some View {
        if let headline {
            Button(action: action) {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    Image(systemName: symbolName(for: headline.severity))
                        .font(.title3)
                        .foregroundStyle(color(for: headline.severity))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text(headline.headerText)
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        if alerts.count > 1 {
                            Text(String(localized: "\(alerts.count) service alerts"))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.forward")
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .accessibilityHidden(true)
                }
                .padding(Theme.Spacing.regular)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(color(for: headline.severity).opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(color(for: headline.severity).opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                alerts.count > 1
                    ? String(localized: "\(alerts.count) service alerts. \(headline.headerText)")
                    : String(localized: "Service alert. \(headline.headerText)")
            )
            .accessibilityHint(String(localized: "Shows all alerts"))
            .accessibilityAddTraits(.isButton)
        }
    }

    private func color(for severity: ServiceAlert.Severity) -> Color {
        switch severity {
        case .severe: return Theme.Palette.cancelled
        case .warning: return Theme.Palette.late
        case .info, .unknown: return Theme.Palette.early
        }
    }

    private func symbolName(for severity: ServiceAlert.Severity) -> String {
        switch severity {
        case .severe: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info, .unknown: return "info.circle.fill"
        }
    }
}

struct ServiceAlertsView: View {
    let alerts: [ServiceAlert]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if alerts.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.circle",
                        title: String(localized: "No alerts"),
                        message: String(localized: "The agency is not reporting any disruption right now.")
                    )
                } else {
                    List(alerts) { alert in
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            Text(alert.headerText)
                                .font(Theme.Typography.rowTitle)
                                .fixedSize(horizontal: false, vertical: true)
                            if !alert.descriptionText.isEmpty {
                                Text(alert.descriptionText)
                                    .font(Theme.Typography.rowSubtitle)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let urlText = alert.url, let url = URL(string: urlText) {
                                Link(String(localized: "More information"), destination: url)
                                    .font(Theme.Typography.caption)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.tight)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(String(localized: "Service alerts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Inline notice

/// A non-blocking explanation with up to two actions. Used for "we are showing
/// the city centre because location is off", which is information the rider needs
/// but not a reason to hide the board behind an error screen.
struct NoticeCard: View {
    let systemImage: String
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if primaryTitle != nil || secondaryTitle != nil {
                FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
                .padding(.top, Theme.Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Skeleton

/// First-load placeholder.
///
/// A bare spinner tells the rider nothing about what is coming; a redacted board
/// tells them the shape of the answer, which makes the same wait feel shorter.
struct NearbySkeleton: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.regular) {
            ForEach(0..<3, id: \.self) { index in
                SectionCard(title: nil) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            Text("Placeholder stop name")
                                .font(Theme.Typography.sectionTitle)
                            Text("Stop 00000 · 000 m")
                                .font(Theme.Typography.rowSubtitle)
                        }
                        .padding(.horizontal, Theme.Spacing.regular)
                        .padding(.top, Theme.Spacing.regular)
                        .padding(.bottom, Theme.Spacing.small)

                        ForEach(0..<(index == 0 ? 3 : 2), id: \.self) { row in
                            DepartureRowView(
                                item: PreviewData.departures[row % PreviewData.departures.count],
                                now: PreviewData.now,
                                showsStop: false
                            )
                            .padding(.horizontal, Theme.Spacing.regular)
                        }
                        .padding(.bottom, Theme.Spacing.small)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        // One announcement instead of a screenful of meaningless redacted rows.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading nearby departures"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Freshness

struct RealtimeFooter: View {
    let updatedAt: Date?
    let now: Date
    let stopCount: Int
    let radiusMeters: Double

    var body: some View {
        VStack(spacing: Theme.Spacing.tight) {
            if let updatedAt {
                Label(
                    String(localized: "Live times · updated \(Format.relativeAge(of: updatedAt, now: now))"),
                    systemImage: "dot.radiowaves.up.forward"
                )
                .foregroundStyle(Theme.Palette.onTime)
            } else {
                Label(
                    String(localized: "Scheduled times · this feed has no live data"),
                    systemImage: "clock"
                )
                .foregroundStyle(Theme.Palette.secondaryText)
            }

            Text(
                String(
                    localized: "\(stopCount) stops within \(Format.distance(meters: radiusMeters))"
                )
            )
            .foregroundStyle(Theme.Palette.tertiaryText)
        }
        .font(Theme.Typography.caption)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.regular)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Mode filter") {
    StatefulPreviewWrapper(Set<TransitMode>()) { selection in
        ModeFilterBar(modes: [.bus, .rail, .tram, .ferry], selection: selection)
            .background(Theme.Palette.background)
    }
}

#Preview("Alerts banner") {
    VStack(spacing: Theme.Spacing.regular) {
        AlertsBanner(alerts: PreviewAlerts.two, action: {})
        AlertsBanner(alerts: [PreviewAlerts.two[0]], action: {})
    }
    .padding()
    .background(Theme.Palette.background)
}

#Preview("Notice") {
    NoticeCard(
        systemImage: "location.slash",
        title: String(localized: "Location is off"),
        message: String(localized: "Showing departures from the city centre. Turn location on to see what leaves from the stop you are standing at."),
        primaryTitle: String(localized: "Open Settings"),
        primaryAction: {},
        secondaryTitle: String(localized: "Search for a stop"),
        secondaryAction: {}
    )
    .padding()
    .background(Theme.Palette.background)
}

#Preview("Skeleton") {
    ScrollView {
        NearbySkeleton()
            .padding(Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
}

#Preview("Footer") {
    VStack {
        RealtimeFooter(updatedAt: Date().addingTimeInterval(-42), now: Date(), stopCount: 6, radiusMeters: 600)
        RealtimeFooter(updatedAt: nil, now: Date(), stopCount: 6, radiusMeters: 600)
    }
    .background(Theme.Palette.background)
}

/// Lets a `@Binding`-taking view be previewed without a host view.
struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initialValue: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initialValue)
        self.content = content
    }

    var body: some View { content($value) }
}

enum PreviewAlerts {
    static let two: [ServiceAlert] = [
        ServiceAlert(
            id: "a1",
            headerText: "Line 42 is on diversion between Allenby and Carmel Market",
            descriptionText: "Roadworks until Friday. Buses are using Yehuda Halevi in both directions and are not calling at Nahalat Binyamin.",
            url: nil,
            effect: .detour,
            severity: .warning,
            activeFrom: nil,
            activeUntil: nil,
            routes: [12],
            stops: [],
            trips: []
        ),
        ServiceAlert(
            id: "a2",
            headerText: "Lift out of service at Central Station",
            descriptionText: "Step-free access to platform 3 is unavailable.",
            url: nil,
            effect: .accessibilityIssue,
            severity: .info,
            activeFrom: nil,
            activeUntil: nil,
            routes: [],
            stops: [2],
            trips: []
        )
    ]
}
