import SwiftUI
import YallaSaKit

/// From and to, as two circles joined by a line.
///
/// The planner used to stack two full-width rows with a swap button beside
/// them, which reads as a form to be filled in. A journey is a line between two
/// points, and drawing it that way makes the screen legible before a single word
/// is read — including which end is missing, because an unfilled circle is
/// obviously empty in a way a grey placeholder row is not.
///
/// ## Direction
///
/// Origin sits on the leading edge and destination on the trailing edge, using
/// `.leading`/`.trailing` rather than left/right, so the whole control mirrors
/// under Hebrew without a second layout. In an RTL build the journey reads
/// right-to-left, which is the direction a Hebrew reader traces it anyway.
struct TripEndpointsBar: View {
    let origin: PlannerEndpoint?
    let destination: PlannerEndpoint?
    let onTapOrigin: () -> Void
    let onTapDestination: () -> Void
    let onSwap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes two names cannot share a row without one of
        // them becoming three truncated characters, so the control stacks.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                stackedEndpoint(origin, kind: .origin, action: onTapOrigin)
                stackedEndpoint(destination, kind: .destination, action: onTapDestination)
                swapButton
            }
        } else {
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                endpoint(origin, kind: .origin, action: onTapOrigin)
                connector
                endpoint(destination, kind: .destination, action: onTapDestination)
            }
        }
    }

    private enum Kind {
        case origin, destination

        var label: String {
            switch self {
            case .origin: return String(localized: "From")
            case .destination: return String(localized: "To")
            }
        }

        var placeholder: String {
            switch self {
            case .origin: return String(localized: "Choose a starting point")
            case .destination: return String(localized: "Choose a destination")
            }
        }

        var symbol: String {
            switch self {
            case .origin: return "location.circle.fill"
            case .destination: return "mappin.circle.fill"
            }
        }
    }

    // MARK: - Horizontal

    private func endpoint(_ value: PlannerEndpoint?, kind: Kind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.small) {
                ZStack {
                    Circle()
                        .fill(value == nil ? Theme.Palette.surfaceRaised : Theme.Palette.accent.opacity(0.14))
                        .frame(width: 52, height: 52)

                    // A dashed ring while empty: it reads as a slot waiting to be
                    // filled rather than a control that is merely off.
                    Circle()
                        .strokeBorder(
                            value == nil ? Theme.Palette.tertiaryText : Theme.Palette.accent,
                            style: StrokeStyle(lineWidth: 2, dash: value == nil ? [4, 3] : [])
                        )
                        .frame(width: 52, height: 52)

                    Image(systemName: kind.symbol)
                        .font(.title3)
                        .foregroundStyle(value == nil ? Theme.Palette.tertiaryText : Theme.Palette.accent)
                }

                Text(kind.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)

                Text(value?.name ?? kind.placeholder)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(value == nil ? Theme.Palette.secondaryText : Theme.Palette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.label))
        .accessibilityValue(Text(value?.name ?? kind.placeholder))
        .accessibilityHint(Text("Opens the place picker"))
        .accessibilityAddTraits(.isButton)
    }

    /// The line between the circles, with swap sitting on it.
    private var connector: some View {
        VStack(spacing: 0) {
            Button(action: onSwap) {
                ZStack {
                    // The rule runs behind the button so the two circles read as
                    // joined rather than as two separate controls.
                    Rectangle()
                        .fill(Theme.Palette.separator)
                        .frame(height: 1)

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.Palette.surface))
                        .overlay(Circle().strokeBorder(Theme.Palette.separator, lineWidth: 0.5))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Swap start and destination"))

            Spacer(minLength: 0)
        }
        // Aligns the rule with the middle of the circles above the labels.
        .padding(.top, 26 - 15)
        .frame(width: 54)
    }

    // MARK: - Accessibility sizes

    private func stackedEndpoint(
        _ value: PlannerEndpoint?,
        kind: Kind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(value == nil ? Theme.Palette.tertiaryText : Theme.Palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                    Text(value?.name ?? kind.placeholder)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(value == nil ? Theme.Palette.secondaryText : Theme.Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.label))
        .accessibilityValue(Text(value?.name ?? kind.placeholder))
        .accessibilityAddTraits(.isButton)
    }

    private var swapButton: some View {
        Button(action: onSwap) {
            Label(String(localized: "Swap start and destination"), systemImage: "arrow.up.arrow.down")
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Palette.accent)
        }
        .buttonStyle(.plain)
    }
}
