import SwiftUI
import YallaSaKit

/// Every line in the active feed, searchable, grouped by mode, favourites first.
struct LinesView: View {
    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var favorites: FavoriteLinesStore
    @EnvironmentObject private var router: AppRouter

    @StateObject private var model = LinesViewModel()

    var body: some View {
        content
            .navigationTitle(Text("Lines"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Line, destination or agency")
            )
            .onChange(of: model.query) { _, _ in model.applyFilter() }
            .onChange(of: favorites.routeIdentifiers) { _, identifiers in
                model.updateFavorites(identifiers)
            }
            .onChange(of: service.activeFeed?.id) { _, _ in
                model.load(service: service, favorites: favorites, force: true)
            }
            .task {
                model.load(service: service, favorites: favorites)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: String(localized: "Reading the timetable…"))

        case .noFeed:
            EmptyStateView(
                systemImage: "tram.circle",
                title: String(localized: "No city installed"),
                message: String(localized: "Add a city in Settings and its lines will show up here."),
                actionTitle: String(localized: "Open Settings"),
                action: { router.selectedTab = .settings }
            )

        case .empty:
            EmptyStateView(
                systemImage: "tram.circle",
                title: String(localized: "No lines in this feed"),
                message: String(localized: "The installed timetable does not contain any routes with scheduled service.")
            )

        case .error(let message):
            ErrorStateView(message: message) {
                model.load(service: service, favorites: favorites, force: true)
            }

        case .content:
            if model.hasResults {
                list
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: String(localized: "No matching lines"),
                    message: String(localized: "Try a line number, a destination, or the name of the operator."),
                    actionTitle: String(localized: "Clear search"),
                    action: { model.query = "" }
                )
            }
        }
    }

    private var list: some View {
        List {
            if !model.favoriteLines.isEmpty {
                Section {
                    ForEach(model.favoriteLines) { line in
                        LineNavigationRow(line: line, isFavorite: true) {
                            favorites.toggleRoute(line.routeIdentifier, index: line.route)
                        }
                    }
                } header: {
                    Label(String(localized: "Favourites"), systemImage: "star.fill")
                }
            }

            ForEach(model.groups) { group in
                Section {
                    ForEach(group.lines) { line in
                        LineNavigationRow(
                            line: line,
                            isFavorite: favorites.containsRoute(line.routeIdentifier)
                        ) {
                            favorites.toggleRoute(line.routeIdentifier, index: line.route)
                        }
                    }
                } header: {
                    HStack(spacing: Theme.Spacing.small) {
                        ModeIcon(group.mode, size: 14)
                        Text(group.title)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text(
                    model.isSearching
                        ? String(localized: "\(model.matchCount) of \(model.totalLineCount) lines")
                        : String(localized: "\(model.totalLineCount) lines in this feed")
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Row

/// A line row that pushes the line's detail onto the enclosing stack.
///
/// The destination is `.route`, not `.pattern`: from the browser the rider has
/// not picked a direction yet, and pattern detail chooses a sensible default.
private struct LineNavigationRow: View {
    let line: LineListItem
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    var body: some View {
        NavigationLink(value: AppDestination.route(line.route)) {
            LineRowView(line: line, isFavorite: isFavorite)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: toggleFavorite) {
                Label(
                    isFavorite ? String(localized: "Unfavourite") : String(localized: "Favourite"),
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            .tint(.yellow)
        }
        .accessibilityAction(named: isFavorite ? Text("Remove from favourites") : Text("Add to favourites")) {
            toggleFavorite()
        }
    }
}

/// The presentational half of a line row. Pure `ViewData` in, pixels out.
struct LineRowView: View {
    let line: LineListItem
    let isFavorite: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            // The same coloured spine the departure cards use. Scanning a list
            // of four hundred lines is a colour-and-shape task before it is a
            // reading task, and this is the app's one visual language for
            // "which line is this".
            Rectangle()
                .fill(Theme.Palette.lineColor(line.badge.backgroundHex))
                .frame(width: 3)
                .clipShape(Capsule())
                .accessibilityHidden(true)

            LineBadge(line.badge, size: .regular)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(displayTitle)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(2)

                if !line.agencyName.isEmpty {
                    Text(line.agencyName)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.footnote)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(minHeight: Theme.minimumTouchTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Feeds routinely repeat the short name in the long name ("42", "42 —
    /// Central"). Showing the badge text twice wastes the only line of the row
    /// a rider actually reads.
    private var displayTitle: String {
        if line.longName.isEmpty || line.longName == line.badge.text {
            return line.badge.text
        }
        return line.longName
    }

    private var accessibilityLabel: String {
        isFavorite
            ? String(localized: "\(line.accessibilityLabel), favourite")
            : line.accessibilityLabel
    }
}

// MARK: - Previews

#if DEBUG
extension LineListItem {
    static func preview(
        route: RouteIndex,
        text: String,
        longName: String,
        agency: String = "Metropolitan Transit",
        mode: TransitMode = .bus,
        background: UInt32 = 0x2E7D32,
        foreground: UInt32 = 0xFFFFFF
    ) -> LineListItem {
        LineListItem(
            route: route,
            routeIdentifier: "R\(route)",
            badge: LineBadgeData(
                text: text,
                backgroundHex: background,
                foregroundHex: foreground,
                mode: mode,
                accessibilityLabel: "\(TransitModeNaming.title(mode)) \(text)"
            ),
            longName: longName,
            agencyName: agency,
            mode: mode,
            patternCount: 2,
            searchKey: LineListItem.fold("\(text) \(longName) \(agency)")
        )
    }

    static var previewSet: [LineListItem] {
        [
            .preview(route: 1, text: "M14", longName: "Union Square — Chelsea Piers"),
            .preview(route: 2, text: "42", longName: "Airport Express", background: 0x1565C0),
            .preview(
                route: 3, text: "Red", longName: "Northgate — Angle Lake",
                agency: "Regional Rail", mode: .subway, background: 0xC62828
            ),
            .preview(
                route: 4, text: "F", longName: "Harbour Ferry",
                agency: "Harbour Board", mode: .ferry, background: 0x0277BD
            )
        ]
    }
}

#Preview("Line rows") {
    List {
        Section {
            LineRowView(line: LineListItem.previewSet[0], isFavorite: true)
            LineRowView(line: LineListItem.previewSet[1], isFavorite: false)
        } header: {
            Label("Favourites", systemImage: "star.fill")
        }
        Section {
            LineRowView(line: LineListItem.previewSet[2], isFavorite: false)
            LineRowView(line: LineListItem.previewSet[3], isFavorite: false)
        } header: {
            Text("Trains")
        }
    }
    .listStyle(.insetGrouped)
}

#Preview("Line row · AX5") {
    List {
        LineRowView(line: LineListItem.previewSet[2], isFavorite: true)
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Line rows · dark") {
    List {
        ForEach(LineListItem.previewSet) { line in
            LineRowView(line: line, isFavorite: line.route == 1)
        }
    }
    .preferredColorScheme(.dark)
}
#endif
