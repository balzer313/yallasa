import YallaSaKit
import SwiftUI

/// Picks one end of a trip.
///
/// The field never blocks: typing only ever schedules work, and every source
/// fills its own section as it arrives rather than the whole list waiting for
/// the slowest one (which is always MapKit).
struct PlaceSearchView: View {
    @StateObject private var viewModel: PlaceSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool
    @State private var text = ""

    private let onSelect: (PlannerEndpoint) -> Void

    init(
        field: PlannerField,
        places: PlacesStore? = nil,
        referenceCoordinate: GeoPoint? = nil,
        service: TransitService = .shared,
        onSelect: @escaping (PlannerEndpoint) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: PlaceSearchViewModel(
                field: field,
                service: service,
                places: places,
                referenceCoordinate: referenceCoordinate
            )
        )
        self.onSelect = onSelect
    }

    #if DEBUG
    init(previewModel: PlaceSearchViewModel, onSelect: @escaping (PlannerEndpoint) -> Void = { _ in }) {
        _viewModel = StateObject(wrappedValue: previewModel)
        self.onSelect = onSelect
    }
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                results
            }
            .background(Theme.Palette.background)
            .navigationTitle(viewModel.field == .origin ? Text("Starting point") : Text("Destination"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Text("Cancel")
                    }
                    .frame(minWidth: Theme.minimumTouchTarget, minHeight: Theme.minimumTouchTarget)
                }
            }
            .overlay {
                if viewModel.isResolving {
                    resolvingOverlay
                }
            }
        }
        .task {
            // A picker that opens without the keyboard costs a tap every single
            // time. The short delay is what makes focus stick inside a sheet.
            try? await Task.sleep(nanoseconds: 350_000_000)
            isFieldFocused = true
        }
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Palette.secondaryText)
                .accessibilityHidden(true)

            TextField(viewModel.field.prompt, text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFieldFocused)
                .frame(minHeight: Theme.minimumTouchTarget)
                .accessibilityLabel(Text(viewModel.field.prompt))

            if !text.isEmpty {
                Button {
                    text = ""
                    viewModel.queryChanged("")
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .frame(width: Theme.minimumTouchTarget, height: Theme.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            } else if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Theme.minimumTouchTarget)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.regular)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Palette.surface)
        .onChange(of: text) { _, newValue in
            viewModel.queryChanged(newValue)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if viewModel.isEmpty && viewModel.hasQuery && !viewModel.isSearching {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: String(localized: "Nothing found"),
                message: String(localized: "No stop or address matches that. Check the spelling, or try the name of a nearby street.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if viewModel.showsCurrentLocation {
                    Section {
                        row(viewModel.currentLocationSuggestion)
                    }
                }
                section(String(localized: "Saved places"), viewModel.savedPlaces)
                section(String(localized: "Recent"), viewModel.recents)
                section(String(localized: "Stops"), viewModel.stops)
                section(String(localized: "Addresses"), viewModel.addresses)

                if viewModel.resolutionFailed {
                    Section {
                        Label(
                            String(localized: "That address could not be located. Try picking another result."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Palette.late)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ suggestions: [PlaceSuggestion]) -> some View {
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    row(suggestion)
                }
            } header: {
                Text(title)
            }
        }
    }

    private func row(_ suggestion: PlaceSuggestion) -> some View {
        Button {
            choose(suggestion)
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: suggestion.symbolName)
                    .font(.body)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(suggestion.title)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .multilineTextAlignment(.leading)
                    if !suggestion.subtitle.isEmpty {
                        Text(suggestion.subtitle)
                            .font(Theme.Typography.rowSubtitle)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.tight)
            .frame(minHeight: Theme.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel(for: suggestion)))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityLabel(for suggestion: PlaceSuggestion) -> String {
        [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            LoadingStateView(message: String(localized: "Locating address…"))
                .padding(Theme.Spacing.large)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        }
        .accessibilityAddTraits(.isModal)
    }

    private func choose(_ suggestion: PlaceSuggestion) {
        Task {
            guard let endpoint = await viewModel.select(suggestion) else { return }
            onSelect(endpoint)
            dismiss()
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Suggestions") {
    PlaceSearchPreviewHost()
}

#Preview("Suggestions · AX5 · dark") {
    PlaceSearchPreviewHost()
        .environment(\.dynamicTypeSize, .accessibility5)
        .preferredColorScheme(.dark)
}

@MainActor
private struct PlaceSearchPreviewHost: View {
    @StateObject private var viewModel: PlaceSearchViewModel

    init() {
        let model = PlaceSearchViewModel(field: .destination)
        model.previewSet(
            saved: [
                PlaceSuggestion(
                    id: "saved-home", source: .saved(.home),
                    title: "Home", subtitle: String(localized: "Home"),
                    endpoint: .place(name: "Home", coordinate: GeoPoint(latitude: 32.07, longitude: 34.78))
                ),
                PlaceSuggestion(
                    id: "saved-work", source: .saved(.work),
                    title: "Office", subtitle: String(localized: "Work"),
                    endpoint: .place(name: "Office", coordinate: GeoPoint(latitude: 32.09, longitude: 34.80))
                ),
            ],
            recents: [
                PlaceSuggestion(
                    id: "recent-1", source: .recent,
                    title: "Engineering Faculty", subtitle: String(localized: "Recent"),
                    endpoint: .place(name: "Engineering Faculty", coordinate: GeoPoint(latitude: 32.1148, longitude: 34.8061))
                ),
            ],
            stops: [
                PlaceSuggestion(
                    id: "stop-100", source: .stop,
                    title: "Rothschild / Allenby", subtitle: "Stop 21041 · 280 m",
                    endpoint: .stop(100, name: "Rothschild / Allenby", coordinate: GeoPoint(latitude: 32.0662, longitude: 34.7712))
                ),
                PlaceSuggestion(
                    id: "stop-140", source: .stop,
                    title: "Arlozorov / Ibn Gabirol", subtitle: "Stop 21188 · 1.4 km",
                    endpoint: .stop(140, name: "Arlozorov / Ibn Gabirol", coordinate: GeoPoint(latitude: 32.0857, longitude: 34.7818))
                ),
            ],
            addresses: [
                PlaceSuggestion(
                    id: "address-0", source: .address,
                    title: "Rothschild Boulevard 42", subtitle: "Tel Aviv-Yafo, Israel",
                    endpoint: nil
                ),
            ]
        )
        _viewModel = StateObject(wrappedValue: model)
    }

    var body: some View {
        PlaceSearchView(previewModel: viewModel)
    }
}
#endif
