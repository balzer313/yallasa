import SwiftUI
import YallaSaKit

/// The departures board, hosted in the sheet over the map on `HomeView`.
///
/// It used to be a whole tab. Splitting "when is my bus" from "where is my bus"
/// across two tabs made the rider carry the connection between them in their
/// head, and once live positions arrived the two screens were showing the same
/// buses in two unrelated ways.
///
/// Still built to be read at a glance and correct to the second: one
/// `TimelineView` drives every countdown on screen rather than a timer per row.
struct NearbyBoard: View {
    @StateObject private var viewModel: NearbyViewModel

    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isShowingAlerts = false

    /// Called when the rider starts scrolling the list, so the host can grow
    /// the sheet instead of making them drag first and read second.
    var onScrollStart: (() -> Void)?

    init(
        service: TransitService = .shared,
        presenter: Presenter? = nil,
        location: LocationProvider,
        onScrollStart: (() -> Void)? = nil
    ) {
        self.onScrollStart = onScrollStart
        _viewModel = StateObject(
            wrappedValue: NearbyViewModel(
                service: service,
                location: location,
                presenter: presenter ?? Presenter(service: service)
            )
        )
    }

    #if DEBUG
    /// Previews only.
    init(previewModel: NearbyViewModel) {
        _viewModel = StateObject(wrappedValue: previewModel)
    }
    #endif

    var body: some View {
        content
            .task { await viewModel.onAppear() }
            .onDisappear { viewModel.onDisappear() }
            .refreshable { await viewModel.refresh() }
            .sheet(isPresented: $isShowingAlerts) {
                NavigationStack {
                    ServiceAlertsView(alerts: service.alerts)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ScrollView { NearbySkeleton() }
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await viewModel.retry() }
            }
        case .locationUnavailable:
            EmptyStateView(
                systemImage: "location.slash",
                title: String(localized: "Location is off"),
                message: String(localized: "Turn on location to see the stops around you, or search for a stop by name."),
                actionTitle: String(localized: "Search lines")
            ) {
                router.selectedTab = .lines
            }
        case .empty:
            EmptyStateView(
                systemImage: "mappin.slash",
                title: String(localized: "No stops nearby"),
                message: String(localized: "There is nothing within walking distance in the timetable you have installed. If you have moved city, add the right one."),
                actionTitle: String(localized: "Add a city")
            ) {
                router.show(.feedPicker, in: .settings)
            }
        case .content:
            board
        }
    }

    private var board: some View {
        // One clock for the whole screen. Every countdown reads from this, so the
        // list ticks in unison and the app schedules one timer instead of dozens.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    // Above the alerts: on a Saturday morning this is the
                    // explanation for everything else on the screen.
                    ShabbatNotice(now: timeline.date)

                    if !service.alerts.isEmpty {
                        AlertsBanner(alerts: service.alerts) { isShowingAlerts = true }
                    }

                    if viewModel.showsPermissionPrompt {
                        NoticeCard(
                            systemImage: "location.circle",
                            title: String(localized: "Show stops around you"),
                            message: String(localized: "Yalla Sa needs your location to find nearby stops. It stays on your phone."),
                            primaryTitle: String(localized: "Allow location"),
                            primaryAction: { viewModel.requestLocationPermission() }
                        )
                    } else if viewModel.usingFallbackLocation {
                        NoticeCard(
                            systemImage: "mappin.and.ellipse",
                            title: String(localized: "Showing the city centre"),
                            message: String(localized: "Without your location, Yalla Sa centres the board on the middle of the network.")
                        )
                    }

                    if !viewModel.availableModes.isEmpty {
                        ModeFilterBar(
                            modes: viewModel.availableModes,
                            selection: $viewModel.selectedModes
                        )
                    }

                    let now = nowSeconds(at: timeline.date)
                    let groups = viewModel.filteredGroups

                    if groups.isEmpty {
                        NoticeCard(
                            systemImage: "line.3.horizontal.decrease.circle",
                            title: String(localized: "Nothing matches that filter"),
                            message: String(localized: "No departures in the next few hours use the modes you picked."),
                            primaryTitle: String(localized: "Clear filter"),
                            primaryAction: { viewModel.clearModeFilter() }
                        )
                    } else {
                        ForEach(groups) { group in
                            NearbyStopCard(
                                group: group,
                                now: now,
                                hasLiveData: service.realtimeUpdatedAt != nil,
                                onOpenStop: {
                                    router.show(.stop(group.stop.stop), in: .nearby)
                                },
                                onOpenDeparture: { departure in
                                    router.show(
                                        .pattern(departure.pattern, position: departure.position),
                                        in: .nearby
                                    )
                                }
                            )
                        }
                    }

                    RealtimeFooter(
                        updatedAt: service.realtimeUpdatedAt,
                        now: timeline.date,
                        stopCount: groups.count,
                        radiusMeters: viewModel.searchRadiusMeters
                    )
                }
                .padding(Theme.Spacing.regular)
                .animation(reduceMotion ? nil : .default, value: viewModel.selectedModes)
            }
            .scrollBounceBehavior(.basedOnSize)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { _ in onScrollStart?() }
            )
        }
    }

    /// Converts wall-clock time into the day frame the board's departures were
    /// computed in, so a board loaded at 23:58 still counts down correctly at
    /// 00:02 without being reloaded.
    private func nowSeconds(at date: Date) -> ServiceSeconds {
        let timeZone = service.timeZone
        let instant = ServiceInstant(date: date, in: timeZone)
        let dayDelta = instant.date.days(since: viewModel.queryDate)
        return instant.seconds + ServiceSeconds(clamping: dayDelta) * 86_400
    }
}
