import SwiftUI
import YallaSaKit

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
            // One screen, three former tabs. Nearby and Map were two halves of
            // the same question — when is my bus, and where is it — and Plan was
            // a third place to type the same two place names. Home is the map,
            // the departures over it, and "Where to?" opening the planner in
            // place rather than sending the rider somewhere else.
            stack(path: $router.nearbyPath) { HomeView() }
                .tabItem { Label(String(localized: "Plan"), systemImage: "bus.fill") }
                .tag(AppTab.nearby)

            stack(path: $router.linesPath) { LinesView() }
                .tabItem { Label(String(localized: "Lines"), systemImage: "tram.fill") }
                .tag(AppTab.lines)

            stack(path: $router.settingsPath) { SettingsView() }
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape.fill") }
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
            PatternDetailView(pattern: pattern, position: position)
        case .route(let route):
            PatternDetailView(route: route)
        case .journey(let item):
            JourneyDetailView(item: item)
        case .feedPicker:
            FeedPickerView()
        }
    }
}
