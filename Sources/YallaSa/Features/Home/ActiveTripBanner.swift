import SwiftUI
import YallaSaKit

/// The running trip, over the map.
///
/// While a trip is active this is the most important thing on the screen, so it
/// sits above the departures board rather than inside it. It answers one
/// question — what do I do next — and everything else on the trip is a tap away
/// on the journey screen.
///
/// The map underneath is already showing live buses, which is the reason this
/// belongs on Home at all: the rider watching their bus approach and the rider
/// following their trip are the same person.
struct ActiveTripBanner: View {
    @ObservedObject var tracker: TripTracker
    let now: ServiceSeconds
    let timeZone: TimeZone
    let onOpen: () -> Void

    var body: some View {
        if let trip = tracker.trip {
            HStack(spacing: Theme.Spacing.medium) {
                Button(action: onOpen) {
                    HStack(spacing: Theme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Spacing.tight) {
                                Text("On the way")
                                    .font(Theme.Typography.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                                if tracker.isNapModeOn {
                                    Image(systemName: "moon.zzz.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Palette.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            Text(nextAction(for: trip))
                                .font(Theme.Typography.rowTitle)
                                .foregroundStyle(Theme.Palette.primaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    tracker.stop()
                } label: {
                    Text("End")
                        .font(Theme.Typography.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("End trip"))
            }
            .padding(Theme.Spacing.regular)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.Palette.accent.opacity(0.12))
            )
            .accessibilityElement(children: .contain)
        }
    }

    /// The next thing the rider has to do, which is the only sentence worth the
    /// space: board this, or get off at that.
    private func nextAction(for trip: JourneyItem) -> String {
        for leg in trip.legs where leg.kind == .ride {
            if now < leg.departureSeconds {
                let line = leg.badge?.text ?? ""
                return String(localized: "Board \(line) at \(leg.fromName)")
            }
            if now < leg.arrivalSeconds {
                return String(localized: "Get off at \(leg.toName)")
            }
        }
        return String(localized: "You are almost there")
    }
}
