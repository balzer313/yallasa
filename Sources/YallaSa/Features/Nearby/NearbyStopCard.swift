import SwiftUI
import YallaSaKit

/// One stop on the Nearby board, with the next few things leaving it.
///
/// The layout answers, in the order a rider actually asks them:
///
/// 1. **How far is it?** Walk time first, in the header, because it decides
///    whether the times below are reachable at all. A 4-minute walk turns a
///    "3 min" departure into one you have already missed.
/// 2. **Which stop?** Name and code.
/// 3. **What is leaving?** The rows.
///
/// The coloured spine down the leading edge is not decoration. A board of six
/// identical white cards is hard to scan; giving each stop the colour of its
/// busiest line makes the list navigable by shape and colour before any text is
/// read, and it mirrors the badge the rider is looking for on the bus itself.
struct NearbyStopCard: View {
    let group: NearbyViewModel.StopGroup
    let now: ServiceSeconds
    let hasLiveData: Bool
    let onOpenStop: () -> Void
    let onOpenDeparture: (DepartureItem) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The colour of the line with the most departures here — the one a rider is
    /// most likely to be waiting for.
    private var spineColor: Color {
        guard let badge = group.departures.first?.badge else {
            return Theme.Palette.separator
        }
        return Theme.Palette.lineColor(badge.backgroundHex)
    }

    private var visibleDepartures: ArraySlice<DepartureItem> {
        group.departures.prefix(NearbyViewModel.rowsPerStop)
    }

    var body: some View {
        SectionCard(title: nil) {
            HStack(spacing: 0) {
                // Hidden from VoiceOver: it repeats the line badges below.
                Rectangle()
                    .fill(spineColor)
                    .frame(width: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    header
                    Divider()
                    departures
                    overflowLink
                }
                .padding(.vertical, Theme.Spacing.small)
                .padding(.horizontal, Theme.Spacing.regular)
            }
        }
        // Clip so the spine takes the card's rounded corners instead of
        // squaring them off.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private var header: some View {
        Button(action: onOpenStop) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.stop.name.isEmpty
                         ? String(localized: "Unnamed stop")
                         : group.stop.name)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Spacing.small)

                if hasLiveData {
                    LiveTag()
                }

                // Omitted at accessibility sizes: it is pure affordance and the
                // space is better spent on the stop name.
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var departures: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleDepartures.enumerated()), id: \.element.id) { index, departure in
                if index > 0 {
                    Divider().opacity(0.4)
                }
                Button {
                    onOpenDeparture(departure)
                } label: {
                    DepartureRowView(item: departure, now: now, showsStop: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var overflowLink: some View {
        if group.departures.count > NearbyViewModel.rowsPerStop {
            Button(action: onOpenStop) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text("See all \(group.departures.count) departures")
                        .font(Theme.Typography.caption.weight(.medium))
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Theme.Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let walk = group.stop.distanceMeters {
            parts.append(Format.walkTime(meters: walk))
        }
        if !group.stop.code.isEmpty {
            parts.append(String(localized: "Stop \(group.stop.code)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var headerAccessibilityLabel: String {
        var parts = [group.stop.name.isEmpty ? String(localized: "Unnamed stop") : group.stop.name]
        if let subtitle { parts.append(subtitle) }
        if hasLiveData { parts.append(String(localized: "Live arrivals available")) }
        return parts.joined(separator: ", ")
    }
}
