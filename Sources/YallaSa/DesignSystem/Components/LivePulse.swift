import SwiftUI

/// The pulsing dot that means "this number is coming from a vehicle, not a
/// timetable".
///
/// Every transit app people like has some version of this, and it is doing real
/// work rather than decoration: the single most important distinction on a
/// departures board is whether a time is *known* or *predicted*, and a rider
/// should be able to tell across a room. Motion is the cheapest way to say
/// "live" without spending a word.
///
/// Two rules it must obey:
///
/// - **Never animate under Reduce Motion.** A pulsing dot is exactly the sort of
///   thing that triggers vestibular symptoms, and the static dot still carries
///   the colour, so nothing is lost.
/// - **Never be the only cue.** Colour plus motion still fails for a colourblind
///   rider looking at a still screenshot, which is why callers pair this with a
///   word or a symbol.
struct LivePulse: View {
    var color: Color = Theme.Palette.onTime
    var diameter: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            // The halo is what reads as a pulse. It is drawn behind and never
            // affects layout, so a row of these stays on its baseline.
            if !reduceMotion {
                Circle()
                    .fill(color.opacity(expanded ? 0 : 0.45))
                    .scaleEffect(expanded ? 2.6 : 1)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                        value: expanded
                    )
            }
            Circle().fill(color)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { expanded = true }
        .accessibilityHidden(true)
    }
}

/// "LIVE" with a pulse, for headers where there is room for a word.
struct LiveTag: View {
    var color: Color = Theme.Palette.onTime
    var text: String = String(localized: "Live")

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            LivePulse(color: color, diameter: 6)
            Text(text)
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        LivePulse()
        LiveTag()
        LiveTag(color: Theme.Palette.late, text: String(localized: "Delayed"))
    }
    .padding()
}
