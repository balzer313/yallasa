import YallaSaKit
import SwiftUI

/// The from/to screen.
///
/// Everything on it is one of four states — loading, empty, error, content —
/// and the results list is the only part that animates, because a planner that
/// reflows its own controls while you are reading them is exhausting to use.
struct PlannerView: View {
    @StateObject private var viewModel: PlannerViewModel
    private let places: PlacesStore?

    /// Set by "plan from here" on a stop or map callout.
    @EnvironmentObject private var handoff: PlanHandoff

    // Rider preferences live in `@AppStorage` rather than in the view model so
    // they survive the screen being torn down, and so the options sheet can bind
    // straight to them without a round trip.
    @AppStorage("planner.maximumTransfers") private var maximumTransfers: Int = 4
    @AppStorage("planner.maximumWalkMeters") private var maximumWalkMeters: Double = 1000
    @AppStorage("planner.requiresWheelchairAccess") private var requiresWheelchairAccess: Bool = false
    @AppStorage("planner.enabledModes") private var enabledModesStorage: String = ""

    @State private var editingField: PlannerField?
    @State private var isShowingOptions = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var skeletonLineHeight: CGFloat = 14

    init(
        service: TransitService = .shared,
        presenter: Presenter? = nil,
        places: PlacesStore? = nil,
        location: LocationProvider? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: PlannerViewModel(service: service, presenter: presenter, location: location)
        )
        self.places = places
    }

    #if DEBUG
    /// Previews only: hosts a view model that has already been pinned to a state.
    init(previewModel: PlannerViewModel, places: PlacesStore? = nil) {
        _viewModel = StateObject(wrappedValue: previewModel)
        self.places = places
    }
    #endif

    private var optionsState: PlannerOptionsState {
        PlannerOptionsState(
            maximumTransfers: maximumTransfers,
            maximumWalkMeters: maximumWalkMeters,
            requiresWheelchairAccess: requiresWheelchairAccess,
            enabledModeRawValues: PlannerOptionsState.modes(fromStorage: enabledModesStorage)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
                endpointCard
                if let places {
                    // Under the endpoints, not above: the rider reads where they
                    // are going from, then picks where to.
                    QuickDestinationsRow(places: places) { place in
                        viewModel.setEndpoint(endpoint(for: place), for: .destination)
                    }
                }
                timeCard
                resultsSection
            }
            .padding(Theme.Spacing.regular)
        }
        .background(Theme.Palette.background)
        .scrollDismissesKeyboard(.interactively)
        // iOS 17 has no scroll-phase callback, so the drag itself is the signal
        // the view model uses to hold back a realtime re-plan.
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in viewModel.scrollingBegan() }
                .onEnded { _ in viewModel.scrollingEnded() }
        )
        .refreshable { await viewModel.refresh() }
        .navigationTitle(Text("Plan a trip"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingOptions = true
                } label: {
                    Label(String(localized: "Options"), systemImage: "slider.horizontal.3")
                }
                .frame(minWidth: Theme.minimumTouchTarget, minHeight: Theme.minimumTouchTarget)
                .accessibilityLabel(Text("Journey options"))
                .accessibilityValue(Text(optionsState.summary))
            }
        }
        .sheet(item: $editingField) { field in
            PlaceSearchView(
                field: field,
                places: places,
                referenceCoordinate: viewModel.currentCoordinate()
            ) { endpoint in
                viewModel.setEndpoint(endpoint, for: field)
            }
        }
        .sheet(isPresented: $isShowingOptions) {
            PlannerOptionsSheet(
                maximumTransfers: $maximumTransfers,
                maximumWalkMeters: $maximumWalkMeters,
                requiresWheelchairAccess: $requiresWheelchairAccess,
                enabledModesStorage: $enabledModesStorage
            )
        }
        .onChange(of: optionsState) { _, newValue in
            viewModel.apply(newValue)
        }
        .task {
            viewModel.apply(optionsState)
            viewModel.onAppear()
            consumeHandoff()
        }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: handoff.pending) { _, _ in consumeHandoff() }
    }

    /// A saved place as a planner endpoint.
    ///
    /// Keeps the stop index when the place was saved as a stop, so the planner
    /// starts from the platform itself rather than walking to a coordinate that
    /// happens to sit on top of one.
    private func endpoint(for place: SavedPlace) -> PlannerEndpoint {
        if let stop = place.stop, stop >= 0 {
            return .stop(stop, name: place.name, coordinate: place.coordinate)
        }
        return .place(name: place.name, coordinate: place.coordinate)
    }

    /// Picks up a "plan from here" request left by another screen.
    ///
    /// `take()` reads and clears in one step, so switching back to this tab later
    /// does not silently re-apply a stop the rider has moved on from.
    private func consumeHandoff() {
        guard let request = handoff.take() else { return }
        let endpoint: PlannerEndpoint
        if let stop = request.stop, stop >= 0 {
            endpoint = .stop(stop, name: request.name, coordinate: request.coordinate)
        } else {
            endpoint = .place(name: request.name, coordinate: request.coordinate)
        }
        viewModel.setEndpoint(endpoint, for: request.role == .origin ? .origin : .destination)
    }

    // MARK: - Endpoints

    private var endpointCard: some View {
        SectionCard(title: nil) {
            TripEndpointsBar(
                origin: viewModel.origin,
                destination: viewModel.destination,
                onTapOrigin: { editingField = .origin },
                onTapDestination: { editingField = .destination },
                onSwap: { viewModel.swapEndpoints() }
            )
            .padding(Theme.Spacing.regular)
        }
    }

    private func endpointRow(_ field: PlannerField) -> some View {
        let endpoint: PlannerEndpoint? = field == .origin ? viewModel.origin : viewModel.destination
        let title = field == .origin ? String(localized: "From") : String(localized: "To")
        let value = endpoint?.name ?? field.prompt

        return Button {
            editingField = field
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: endpoint?.symbolName ?? "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(title)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Text(value)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(endpoint == nil ? Theme.Palette.tertiaryText : Theme.Palette.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.small)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
            .padding(.vertical, Theme.Spacing.small)
            .frame(minHeight: Theme.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title): \(value)"))
        .accessibilityHint(Text("Opens the place picker"))
        .accessibilityAddTraits(.isButton)
    }

    private var swapButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { viewModel.swapEndpoints() }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
                .background(Theme.Palette.surfaceRaised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSwap)
        .opacity(viewModel.canSwap ? 1 : 0.4)
        .accessibilityLabel(Text("Swap start and destination"))
    }

    // MARK: - Time

    private var timeCard: some View {
        SectionCard(title: String(localized: "When"), systemImage: "clock") {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                timeModePicker
                if viewModel.timeMode.usesExplicitTime {
                    DatePicker(
                        selection: Binding(
                            get: { viewModel.selectedDate },
                            set: { viewModel.setSelectedDate($0) }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        Text(viewModel.timeMode.title)
                    }
                    .datePickerStyle(.compact)
                    // The picker must speak the feed's clock, not the phone's —
                    // planning Tel Aviv buses from London is a real use case.
                    .environment(\.timeZone, viewModel.timeZone)
                    .frame(minHeight: Theme.minimumTouchTarget)
                }
                if viewModel.showsTimeZoneHint {
                    Label(viewModel.timeZoneHint, systemImage: "globe")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityValue(Text(viewModel.timeSummary))
        }
    }

    private var timeModePicker: some View {
        let binding = Binding(
            get: { viewModel.timeMode },
            set: { viewModel.setTimeMode($0) }
        )
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                // A three-way segmented control cannot hold AX5 text without
                // truncating, and a truncated "Arrive by" is unreadable.
                Picker(selection: binding) {
                    ForEach(PlannerTimeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Departure time")
                }
                .pickerStyle(.menu)
                .frame(minHeight: Theme.minimumTouchTarget)
            } else {
                Picker(selection: binding) {
                    ForEach(PlannerTimeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Departure time")
                }
                .pickerStyle(.segmented)
                .frame(minHeight: Theme.minimumTouchTarget)
            }
        }
        .accessibilityLabel(Text("Departure time"))
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        switch viewModel.phase {
        case .idle, .loading:
            skeleton
        case .results(let items):
            resultsList(items)
        case .empty(let reason):
            // A blank result on Shabbat is not a failure to find a route, it is
            // the correct answer — and "No service connects these places at this
            // time" reads as the planner giving up. Naming Shabbat, and offering
            // to search from the moment service resumes, is the difference
            // between an app that looks broken and one that is simply honest.
            if reason == .noResults, let resumes = shabbatResumption {
                EmptyStateView(
                    systemImage: "moon.stars.fill",
                    title: String(localized: "Shabbat"),
                    message: String(localized: "Most lines do not run right now. Service returns around \(Format.clock(resumes, in: ShabbatClock.israelTimeZone))."),
                    actionTitle: String(localized: "Plan for after Shabbat"),
                    action: { planFromEndOfShabbat(resumes) }
                )
                .frame(maxWidth: .infinity)
            } else {
                EmptyStateView(
                    systemImage: reason.systemImage,
                    title: reason.title,
                    message: reason.message,
                    actionTitle: reason.actionTitle,
                    action: action(for: reason)
                )
                .frame(maxWidth: .infinity)
            }
        case .failed(let message):
            ErrorStateView(message: message) {
                viewModel.plan()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func resultsList(_ items: [JourneyItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text("\(items.count) options")
                    .font(Theme.Typography.sectionTitle)
                Spacer(minLength: Theme.Spacing.small)
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Updating live times"))
                }
            }

            // One clock for the whole list. Per-row timers on a list that can hold
            // six cards with four legs each is how a planner burns a battery.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                LazyVStack(spacing: Theme.Spacing.medium) {
                    ForEach(items) { item in
                        NavigationLink(value: AppDestination.journey(item)) {
                            JourneyCardView(
                                item: item,
                                now: PlanClock.seconds(
                                    at: context.date,
                                    in: viewModel.timeZone,
                                    frame: item.baseDate
                                ),
                                timeZone: viewModel.timeZone,
                                // "Leave now" gets a countdown; a trip planned
                                // for Tuesday gets clock times, because "in 3
                                // days" answers nothing.
                                isImmediate: viewModel.timeMode == .leaveNow
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var skeleton: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ForEach(0..<3, id: \.self) { _ in
                SectionCard(title: nil) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .fill(Theme.Palette.surfaceRaised)
                            .frame(height: skeletonLineHeight * 1.6)
                            .frame(maxWidth: 180, alignment: .leading)
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .fill(Theme.Palette.surfaceRaised)
                            .frame(height: skeletonLineHeight)
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .fill(Theme.Palette.surfaceRaised)
                            .frame(height: skeletonLineHeight)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // The placeholders carry no information; VoiceOver gets the one fact
        // that matters instead of three rows of empty rectangles.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Finding journeys"))
    }

    /// When service resumes, if the moment being planned for is inside Shabbat.
    ///
    /// Keyed on the departure time the rider actually asked about rather than on
    /// "now": someone planning a Saturday afternoon trip on Thursday should get
    /// the same explanation, not a puzzling empty list.
    private var shabbatResumption: Date? {
        let target = viewModel.timeMode.usesExplicitTime ? viewModel.selectedDate : Date()
        return ShabbatClock.endOfShabbat(containing: target)
    }

    /// Re-runs the search from just after havdalah.
    ///
    /// Two minutes past, not exactly on it: asking for the instant service
    /// resumes tends to land before the first vehicle has left its depot, which
    /// returns another empty list and looks like the button did nothing.
    private func planFromEndOfShabbat(_ resumes: Date) {
        viewModel.timeMode = .leaveAt
        viewModel.selectedDate = resumes.addingTimeInterval(120)
        viewModel.plan()
    }

    private func action(for reason: PlannerEmptyReason) -> (() -> Void)? {
        switch reason {
        case .noFeed:
            return nil
        case .notEnoughInput, .noStopsNearDestination, .sameEndpoints:
            return { editingField = .destination }
        case .needsLocation, .noStopsNearOrigin:
            return { editingField = .origin }
        case .noResults:
            return { isShowingOptions = true }
        case .dateNotCovered:
            return { Task { await viewModel.refreshFeed() } }
        }
    }
}

// MARK: - Options sheet

/// Bound directly to the `@AppStorage` values that own the rider's preferences.
struct PlannerOptionsSheet: View {
    @Binding var maximumTransfers: Int
    @Binding var maximumWalkMeters: Double
    @Binding var requiresWheelchairAccess: Bool
    @Binding var enabledModesStorage: String

    @Environment(\.dismiss) private var dismiss

    private var state: PlannerOptionsState {
        PlannerOptionsState(
            maximumTransfers: maximumTransfers,
            maximumWalkMeters: maximumWalkMeters,
            requiresWheelchairAccess: requiresWheelchairAccess,
            enabledModeRawValues: PlannerOptionsState.modes(fromStorage: enabledModesStorage)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $maximumTransfers, in: 0...4) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text("Maximum transfers")
                            Text(Format.transferCount(maximumTransfers))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                    .frame(minHeight: Theme.minimumTouchTarget)
                    .accessibilityValue(Text(Format.transferCount(maximumTransfers)))
                } header: {
                    Text("Transfers")
                }

                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Up to \(Format.distance(meters: maximumWalkMeters)) to or from a stop")
                            .font(Theme.Typography.rowSubtitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Slider(value: $maximumWalkMeters, in: 200...2500, step: 100) {
                            Text("Maximum walking distance")
                        } minimumValueLabel: {
                            Text(verbatim: Format.distance(meters: 200))
                        } maximumValueLabel: {
                            Text(verbatim: Format.distance(meters: 2500))
                        }
                        .frame(minHeight: Theme.minimumTouchTarget)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Maximum walking distance"))
                    .accessibilityValue(Text(Format.distance(meters: maximumWalkMeters)))
                } header: {
                    Text("Walking")
                }

                Section {
                    ForEach(PlannerOptionsState.selectableModes, id: \.self) { mode in
                        Toggle(isOn: modeBinding(mode)) {
                            Label {
                                Text(mode.plannerDisplayName)
                            } icon: {
                                ModeIcon(mode)
                            }
                        }
                        .frame(minHeight: Theme.minimumTouchTarget)
                    }
                } header: {
                    Text("Modes")
                } footer: {
                    Text("Turning everything on is the same as no filter, so newly added services keep showing up.")
                }

                Section {
                    Toggle(isOn: $requiresWheelchairAccess) {
                        Label {
                            Text("Wheelchair accessible only")
                        } icon: {
                            Image(systemName: "figure.roll")
                        }
                    }
                    .frame(minHeight: Theme.minimumTouchTarget)
                } footer: {
                    Text("Only uses stops and vehicles the feed marks as step-free. Feeds with no accessibility data will return fewer journeys.")
                }
            }
            .navigationTitle(Text("Journey options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Text("Done").fontWeight(.semibold)
                    }
                    .frame(minWidth: Theme.minimumTouchTarget, minHeight: Theme.minimumTouchTarget)
                }
            }
        }
    }

    private func modeBinding(_ mode: TransitMode) -> Binding<Bool> {
        Binding(
            get: { state.isEnabled(mode) },
            set: { isEnabled in
                var updated = state
                updated.setEnabled(isEnabled, for: mode)
                enabledModesStorage = updated.modesStorageValue
            }
        )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Results") {
    NavigationStack {
        PlannerPreviewHost(
            phase: .results(PlannerPreviewData.journeys),
            destination: .place(
                name: "Engineering Faculty",
                coordinate: GeoPoint(latitude: 32.1148, longitude: 34.8061)
            )
        )
    }
}

#Preview("Loading") {
    NavigationStack {
        PlannerPreviewHost(phase: .loading, destination: nil)
    }
}

#Preview("No stops near start") {
    NavigationStack {
        PlannerPreviewHost(phase: .empty(.noStopsNearOrigin), destination: nil)
    }
}

#Preview("Date not covered · AX5") {
    NavigationStack {
        PlannerPreviewHost(
            phase: .empty(.dateNotCovered(PlannerPreviewData.baseDate)),
            destination: nil
        )
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Options sheet") {
    PlannerOptionsSheetPreviewHost()
}

/// Hosts a `PlannerView` whose view model has been pushed straight into a state,
/// so the preview never opens a graph.
@MainActor
private struct PlannerPreviewHost: View {
    @StateObject private var viewModel: PlannerViewModel

    init(phase: PlannerViewModel.Phase, destination: PlannerEndpoint?) {
        let model = PlannerViewModel()
        model.previewSet(phase: phase, destination: destination)
        _viewModel = StateObject(wrappedValue: model)
    }

    var body: some View {
        PlannerView(previewModel: viewModel)
    }
}

private struct PlannerOptionsSheetPreviewHost: View {
    @State private var transfers = 2
    @State private var walk: Double = 800
    @State private var wheelchair = true
    @State private var modes = "2,3"

    var body: some View {
        PlannerOptionsSheet(
            maximumTransfers: $transfers,
            maximumWalkMeters: $walk,
            requiresWheelchairAccess: $wheelchair,
            enabledModesStorage: $modes
        )
    }
}
#endif
