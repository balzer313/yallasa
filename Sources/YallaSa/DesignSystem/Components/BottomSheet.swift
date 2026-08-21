import SwiftUI

/// A draggable sheet that sits over a live map without covering it.
///
/// ## Why this is hand-rolled
///
/// `.presentationDetents` looks like the right tool and is not, for one
/// disqualifying reason: a `.sheet` is modal, and only one can be presented from
/// a view at a time. The map underneath needs to keep presenting its own sheets
/// — tap a bus, tap a stop — and a board occupying the app's single sheet slot
/// makes both impossible. Owning the geometry costs about a hundred lines and
/// buys a map that stays fully interactive behind a board that is always there.
///
/// ## The three positions
///
/// - **peek** — a handful of departures. The default, because the answer to
///   "when is my bus" is usually in the first two rows and the rider wants to
///   see where they are at the same time.
/// - **half** — the board and a usable map.
/// - **full** — the board, for scrolling a long list.
///
/// Snapping to three fixed positions rather than resting anywhere the finger
/// stops is deliberate: a sheet left at 43% is a sheet the rider has to think
/// about, and the map behind it is either useful or it is not.
struct BottomSheet<Content: View>: View {
    enum Snap: CaseIterable {
        case peek, half, full

        /// Fraction of the container the sheet's *top edge* sits at.
        var topFraction: CGFloat {
            switch self {
            case .peek: return 0.62
            case .half: return 0.38
            case .full: return 0.06
            }
        }
    }

    @Binding var snap: Snap
    @ViewBuilder var content: Content

    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let resting = height * snap.topFraction
            // Rubber-banding past the top would let the sheet leave the screen;
            // past the bottom it would strand the rider with no board at all.
            let offset = min(max(resting + drag, height * Snap.full.topFraction - 24), height * 0.88)

            VStack(spacing: 0) {
                grabber
                content
            }
            .frame(width: proxy.size.width, height: height - offset + 40, alignment: .top)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: Theme.Radius.sheet,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Theme.Radius.sheet,
                    style: .continuous
                )
                .fill(.regularMaterial)
                // A soft lift rather than a border: over a map, a hairline reads
                // as a seam and a shadow reads as a surface above it.
                .shadow(color: .black.opacity(0.18), radius: 14, y: -3)
            )
            .offset(y: offset)
            .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 320, damping: 32), value: snap)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in
                        snap = Self.destination(
                            from: snap,
                            translation: value.translation.height,
                            velocity: value.predictedEndTranslation.height - value.translation.height,
                            height: height
                        )
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var grabber: some View {
        // The whole strip is the target, not just the pill: a 5-point-tall
        // capsule is not something anyone can reliably hit while walking.
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.Palette.tertiaryText.opacity(0.6))
                .frame(width: 38, height: 5)
                .padding(.vertical, Theme.Spacing.small)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("Departures panel"))
        .accessibilityValue(Text(accessibilityPosition))
        .accessibilityHint(Text("Swipe up or down to resize"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: snap = snap.taller
            case .decrement: snap = snap.shorter
            @unknown default: break
            }
        }
    }

    private var accessibilityPosition: String {
        switch snap {
        case .peek: return String(localized: "Collapsed")
        case .half: return String(localized: "Half open")
        case .full: return String(localized: "Expanded")
        }
    }

    /// Where a drag should land.
    ///
    /// Velocity is consulted before distance so a quick flick moves a position
    /// even though the finger barely travelled — a sheet that ignores a flick
    /// feels stuck.
    static func destination(
        from current: Snap,
        translation: CGFloat,
        velocity: CGFloat,
        height: CGFloat
    ) -> Snap {
        let flick: CGFloat = 12
        if velocity < -flick { return current.taller }
        if velocity > flick { return current.shorter }

        // Otherwise land on whichever position the sheet's top edge is nearest.
        let landed = height * current.topFraction + translation
        return Snap.allCases.min {
            abs(height * $0.topFraction - landed) < abs(height * $1.topFraction - landed)
        } ?? current
    }
}

extension BottomSheet.Snap {
    var taller: Self {
        switch self {
        case .peek: return .half
        case .half, .full: return .full
        }
    }

    var shorter: Self {
        switch self {
        case .full: return .half
        case .half, .peek: return .peek
        }
    }
}
