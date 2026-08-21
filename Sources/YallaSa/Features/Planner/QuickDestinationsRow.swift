import SwiftUI
import YallaSaKit

/// One-tap destinations across the top of the planner.
///
/// `PlacesStore` has held home, work, favourites and recents since the app was
/// written, but the only way to reach them was to open the destination field and
/// search. That makes the most common journey a rider ever plans — the one home
/// — take four taps, when every planner people actually like makes it one.
///
/// Ordering is deliberate and fixed: home, work, then favourites, then recents.
/// A row that reorders itself by frequency saves a tap occasionally and costs
/// muscle memory permanently, which is a bad trade on a screen used in a hurry
/// at a bus stop.
struct QuickDestinationsRow: View {
    @ObservedObject var places: PlacesStore
    let onSelect: (SavedPlace) -> Void

    private var entries: [SavedPlace] {
        var result: [SavedPlace] = []
        if let home = places.home { result.append(home) }
        if let work = places.work { result.append(work) }
        result.append(contentsOf: places.favorites)
        // Recents fill whatever room is left, and never repeat something already
        // pinned above.
        let pinned = Set(result.map(\.dedupeKey))
        result.append(contentsOf: places.recents.filter { !pinned.contains($0.dedupeKey) }.prefix(6))
        return result
    }

    var body: some View {
        if !entries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(entries) { place in
                        Button {
                            onSelect(place)
                        } label: {
                            chip(place)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Inset so the first and last chips are not flush against the
                // screen edge when the row is scrolled to either end.
                .padding(.horizontal, Theme.Spacing.regular)
            }
            // Cancels the parent ScrollView's padding so the row bleeds to the
            // edges and reads as scrollable rather than clipped.
            .padding(.horizontal, -Theme.Spacing.regular)
            .accessibilityLabel(Text("Saved places"))
        }
    }

    private func chip(_ place: SavedPlace) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: place.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(place.name)
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.separator.opacity(0.6), lineWidth: 0.5))
        .frame(minHeight: Theme.minimumTouchTarget - Theme.Spacing.small)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(place.name))
        .accessibilityHint(Text("Sets this as the destination"))
        .accessibilityAddTraits(.isButton)
    }
}
