import SwiftUI
import MoveItKit

@MainActor
final class StopDetailViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case content
        case empty
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var header: StopItem?
    @Published private(set) var departures: [DepartureItem] = []
    @Published private(set) var queryDate: ServiceDate
    @Published var selectedPattern: PatternIndex?

    let stop: StopIndex
    private let service: TransitService
    private let presenter: Presenter
    private var loadTask: Task<Void, Never>?

    init(stop: StopIndex, service: TransitService, presenter: Presenter) {
        self.stop = stop
        self.service = service
        self.presenter = presenter
        self.queryDate = ServiceDate(date: Date(), in: service.timeZone)
    }

    /// One chip per line calling here.
    ///
    /// Derived from what is actually departing rather than from the graph, so a
    /// line that has finished for the night does not offer a filter that yields
    /// an empty list. Keyed by pattern, since that is what a departure carries.
    var availableLines: [(pattern: PatternIndex, badge: LineBadgeData)] {
        var seen = Set<PatternIndex>()
        var result: [(pattern: PatternIndex, badge: LineBadgeData)] = []
        for departure in departures where seen.insert(departure.pattern).inserted {
            result.append((pattern: departure.pattern, badge: departure.badge))
        }
        return result
    }

    var visibleDepartures: [DepartureItem] {
        guard let selectedPattern else { return departures }
        return departures.filter { $0.pattern == selectedPattern }
    }

    func onAppear() async {
        service.startRealtimePolling()
        await load()
    }

    func onDisappear() {
        loadTask?.cancel()
        service.stopRealtimePolling()
    }

    func refresh() async {
        await service.refreshRealtime()
        await load()
    }

    func load() async {
        loadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.queryDate = ServiceDate(date: Date(), in: self.service.timeZone)
            self.header = self.presenter.stopItem(self.stop, distanceMeters: nil)

            // A rider standing at an interchange wants every platform, not the
            // one the tap happened to land on.
            let stops = self.service.siblingStops(of: self.stop)
            var collected: [DepartureItem] = []
            for candidate in stops {
                guard !Task.isCancelled else { return }
                let raw = await self.service.departures(atStop: candidate, limit: 40)
                collected.append(contentsOf: raw.compactMap { self.presenter.departureItem($0, walkMeters: nil) })
            }
            guard !Task.isCancelled else { return }
            collected.sort { $0.departureSeconds < $1.departureSeconds }
            self.departures = collected
            self.phase = collected.isEmpty ? .empty : .content
        }
        loadTask = task
        await task.value
    }
}

struct StopDetailView: View {
    @StateObject private var viewModel: StopDetailViewModel

    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var favorites: FavoriteLinesStore
    @EnvironmentObject private var handoff: PlanHandoff
    @Environment(\.presenter) private var presenter

    init(stop: StopIndex, service: TransitService = .shared, presenter: Presenter? = nil) {
        _viewModel = StateObject(
            wrappedValue: StopDetailViewModel(
                stop: stop,
                service: service,
                presenter: presenter ?? Presenter(service: service)
            )
        )
    }

    var body: some View {
        content
            .navigationTitle(Text(viewModel.header?.name ?? String(localized: "Stop")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { favoriteButton }
            }
            .task { await viewModel.onAppear() }
            .onDisappear { viewModel.onDisappear() }
            .refreshable { await viewModel.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ScrollView { NearbySkeleton() }
        case .failed(let message):
            ErrorStateView(message: message) { Task { await viewModel.load() } }
        case .empty:
            EmptyStateView(
                systemImage: "moon.zzz",
                title: String(localized: "Nothing more today"),
                message: String(localized: "No further departures from this stop in the timetable. Check the line's full timetable for another day.")
            )
        case .content:
            board
        }
    }

    private var board: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if let header = viewModel.header {
                        SectionCard(title: nil) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                                StopRowView(item: header)
                                planActions
                            }
                        }
                    }

                    if viewModel.availableLines.count > 1 {
                        lineFilter
                    }

                    let now = nowSeconds(at: timeline.date)
                    ForEach(viewModel.visibleDepartures) { departure in
                        Button {
                            router.show(
                                .pattern(departure.pattern, position: departure.position),
                                in: router.selectedTab
                            )
                        } label: {
                            DepartureRowView(item: departure, now: now, showsStop: true)
                        }
                        .buttonStyle(.plain)
                    }

                    RealtimeFooter(
                        updatedAt: service.realtimeUpdatedAt,
                        now: timeline.date,
                        stopCount: 1,
                        radiusMeters: 0
                    )
                }
                .padding(Theme.Spacing.regular)
            }
        }
    }

    /// Filtering is client-side over already-loaded departures, so tapping a line
    /// is instant rather than a round trip to the engine.
    private var lineFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    viewModel.selectedPattern = nil
                } label: {
                    Text("All")
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, Theme.Spacing.medium)
                        .padding(.vertical, Theme.Spacing.small)
                        .background(
                            Capsule().fill(
                                viewModel.selectedPattern == nil
                                    ? Theme.Palette.accent.opacity(0.18)
                                    : Theme.Palette.surfaceRaised
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selectedPattern == nil ? [.isSelected] : [])

                ForEach(viewModel.availableLines, id: \.pattern) { line in
                    Button {
                        viewModel.selectedPattern = viewModel.selectedPattern == line.pattern ? nil : line.pattern
                    } label: {
                        LineBadge(line.badge, size: .small)
                            .opacity(
                                viewModel.selectedPattern == nil || viewModel.selectedPattern == line.pattern
                                    ? 1 : 0.4
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(line.badge.accessibilityLabel))
                    .accessibilityAddTraits(viewModel.selectedPattern == line.pattern ? [.isSelected] : [])
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
        }
    }

    private var planActions: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                startPlan(asOrigin: true)
            } label: {
                Label(String(localized: "From here"), systemImage: "figure.walk.departure")
                    .font(Theme.Typography.caption)
            }
            .buttonStyle(.bordered)

            Button {
                startPlan(asOrigin: false)
            } label: {
                Label(String(localized: "To here"), systemImage: "figure.walk.arrival")
                    .font(Theme.Typography.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    private func startPlan(asOrigin: Bool) {
        guard let header = viewModel.header else { return }
        handoff.request(
            PlanHandoff.Request(
                role: asOrigin ? .origin : .destination,
                stop: viewModel.stop,
                stopIdentifier: presenter?.stopIdentifier(viewModel.stop),
                coordinate: header.coordinate,
                name: header.name
            )
        )
        router.selectedTab = .plan
    }

    private var favoriteButton: some View {
        let identifier = presenter?.stopIdentifier(viewModel.stop)
        let isFavorite = identifier.map { favorites.containsStop($0) } ?? false
        return Button {
            if let identifier {
                favorites.toggleStop(identifier, index: viewModel.stop)
            }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
        }
        .disabled(identifier == nil)
        .accessibilityLabel(
            Text(isFavorite ? String(localized: "Remove from favourites") : String(localized: "Add to favourites"))
        )
    }

    private func nowSeconds(at date: Date) -> ServiceSeconds {
        let instant = ServiceInstant(date: date, in: service.timeZone)
        let dayDelta = instant.date.days(since: viewModel.queryDate)
        return instant.seconds + ServiceSeconds(clamping: dayDelta) * 86_400
    }
}
