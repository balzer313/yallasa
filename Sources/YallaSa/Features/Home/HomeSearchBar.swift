import SwiftUI
import YallaSaKit

/// The "where to?" bar at the top of the home board.
///
/// Every transit app people like opens with this, and it is not fashion: the
/// two things a rider wants are *what leaves from here* and *take me
/// somewhere*, and the second had been buried behind a tab. Putting it at the
/// top of the board makes planning a trip one tap from the first screen,
/// without demoting the departures underneath it.
///
/// It is a button styled as a field rather than a real `TextField`. Tapping it
/// hands over to the planner, which already owns place search, recents and
/// saved places — duplicating any of that here would mean two search
/// implementations that drift apart.
struct HomeSearchBar: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)

                Text("Where to?")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.secondaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.regular)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Palette.separator.opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Plan a trip"))
        .accessibilityHint(Text("Opens the journey planner"))
        .accessibilityAddTraits(.isButton)
    }
}
