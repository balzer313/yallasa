import SwiftUI
import MoveItKit

/// The tab shell.
///
/// Owns two things and nothing else: which tab is showing, and how an
/// `AppDestination` becomes a view. Every screen is reachable from every stack,
/// so a stop opened from the map and a stop opened from a departure row are the
/// same screen with the same state.
struct RootView: View {
    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var places: PlacesStore
    @EnvironmentObject private var handoff: PlanHandoff

    @State private var presenter: Presenter?

    var body: some View {
        Group {
            switch service.state {
            case .idle:
                LoadingStateView(message: String(localized: "Starting up…"))
            case .needsFeed, .installing:
                FeedGateView()
            case .ready:
                tabs
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await service.bootstrap() }
                }
            }
        }
        .environment(\.presenter, presenter ?? Presenter(service: service))
        .onAppear {
            if presenter == nil { presenter = Presenter(service: service) }
        }
        .onChange(of: service.activeFeed?.id) { _, _ in
            // A feed swap renumbers every index in the graph, so anything already
            // pushed now points somewhere else entirely.
            router.popAllToRoot()
            presenter = Presenter(service: service)
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            stack(path: $router.nearbyPath) {
                NearbyView(service: service, presenter: presenter, location: location)
            }
                .tabItem { Label(String(localized: "Nearby"), systemImage: "location.circle") }
                .tag(AppTab.nearby)

            stack(path: $router.planPath) {
                PlannerView(service: service, presenter: presenter, places: places, location: location)
            }
            .tabItem { Label(String(localized: "Plan"), systemImage: "arrow.triangle.turn.up.right.circle") }
            .tag(AppTab.plan)

            stack(path: $router.linesPath) { LinesView() }
                .tabItem { Label(String(localized: "Lines"), systemImage: "list.bullet") }
                .tag(AppTab.lines)

            stack(path: $router.mapPath) { MapView() }
                .tabItem { Label(String(localized: "Map"), systemImage: "map") }
                .tag(AppTab.map)

            stack(path: $router.settingsPath) { SettingsView() }
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }

    /// Re-tapping the active tab pops it to root, which is the behaviour every
    /// iOS user already has in their fingers.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { newValue in
                if newValue == router.selectedTab {
                    router.popToRoot(newValue)
                } else {
                    router.selectedTab = newValue
                }
            }
        )
    }

    private func stack<Content: View>(
        path: Binding<[AppDestination]>,
        @ViewBuilder root: () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            root()
                .navigationDestination(for: AppDestination.self) { destination in
                    view(for: destination)
                }
        }
    }

    @ViewBuilder
    private func view(for destination: AppDestination) -> some View {
        switch destination {
        case .stop(let stop):
            StopDetailView(stop: stop)
        case .pattern(let pattern, let position):
            PatternDetailView(route: nil, pattern: pattern, position: position)
        case .route(let route):
            PatternDetailView(route: route, pattern: nil, position: nil)
        case .journey(let item):
            JourneyDetailView(item: item)
        case .feedPicker:
            FeedPickerView()
        }
    }
}
