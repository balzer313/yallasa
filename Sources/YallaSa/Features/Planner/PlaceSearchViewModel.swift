import CoreLocation
import Foundation
import MapKit
import YallaSaKit
import SwiftUI

// MARK: - Suggestion

/// One row in the place picker, whatever produced it.
struct PlaceSuggestion: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case currentLocation
        case saved(SavedPlace.Kind)
        case recent
        case stop
        case address
    }

    var id: String
    var source: Source
    var title: String
    var subtitle: String
    /// Already usable. Address rows arrive with `nil` and are geocoded on tap,
    /// because resolving every completion as it scrolls past would burn the
    /// MapKit rate limit in seconds.
    var endpoint: PlannerEndpoint?

    var symbolName: String {
        switch source {
        case .currentLocation: return "location.fill"
        case .saved(.home): return "house.fill"
        case .saved(.work): return "briefcase.fill"
        case .saved(.favorite): return "star.fill"
        case .saved(.recent), .recent: return "clock.arrow.circlepath"
        case .stop: return "signpost.right.fill"
        case .address: return "mappin.circle.fill"
        }
    }
}

// MARK: - Address completer

/// Wraps `MKLocalSearchCompleter`.
///
/// The delegate is a plain Cocoa protocol with no actor isolation, so it needs a
/// plain `NSObject`; making the `@MainActor` view model adopt it directly is the
/// kind of thing that compiles today and stops compiling under strict
/// concurrency tomorrow. Everything here is touched on the main thread only —
/// MapKit both requires and guarantees that for this class.
final class AddressCompleterProxy: NSObject, MKLocalSearchCompleterDelegate {
    /// Results, tagged with the query they answer so a slow response cannot
    /// overwrite a newer one.
    var onResults: (@Sendable (String, [PlaceSuggestion]) -> Void)?

    private let completer = MKLocalSearchCompleter()
    private var completionsByID: [String: MKLocalSearchCompletion] = [:]
    private var currentQuery = ""

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, region: MKCoordinateRegion?) {
        currentQuery = query
        guard !query.isEmpty else {
            completer.cancel()
            completionsByID.removeAll()
            onResults?(query, [])
            return
        }
        if let region { completer.region = region }
        completer.queryFragment = query
    }

    func cancel() {
        completer.cancel()
    }

    // MARK: MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        var suggestions: [PlaceSuggestion] = []
        var map: [String: MKLocalSearchCompletion] = [:]
        suggestions.reserveCapacity(completer.results.count)

        for (offset, completion) in completer.results.enumerated() {
            // The index keeps the id stable within one result set even when two
            // completions share a title, which happens constantly with chains.
            let id = "address-\(offset)-\(completion.title)|\(completion.subtitle)"
            map[id] = completion
            suggestions.append(
                PlaceSuggestion(
                    id: id,
                    source: .address,
                    title: completion.title,
                    subtitle: completion.subtitle,
                    endpoint: nil
                )
            )
        }
        completionsByID = map
        onResults?(currentQuery, suggestions)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Address lookup failing is not worth surfacing: it fails routinely with
        // no network, and the stop results — which are local — still stand.
        completionsByID.removeAll()
        onResults?(currentQuery, [])
    }

    // MARK: Resolution

    /// Geocodes one suggestion. MapKit calls back on the main queue.
    func resolve(id: String, name: String, then handler: @escaping @Sendable (PlannerEndpoint?) -> Void) {
        guard let completion = completionsByID[id] else {
            handler(nil)
            return
        }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        search.start { response, _ in
            guard let coordinate = response?.mapItems.first?.placemark.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate)
            else {
                handler(nil)
                return
            }
            handler(
                .place(
                    name: name,
                    coordinate: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                )
            )
        }
    }
}

// MARK: - View model

/// Drives the endpoint picker.
///
/// Five sources feed one list, in the order a rider expects to find them: where
/// they are, where they always go, where they went last, the stops around them,
/// and finally the whole map.
@MainActor
final class PlaceSearchViewModel: ObservableObject {
    @Published private(set) var savedPlaces: [PlaceSuggestion] = []
    @Published private(set) var recents: [PlaceSuggestion] = []
    @Published private(set) var stops: [PlaceSuggestion] = []
    @Published private(set) var addresses: [PlaceSuggestion] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isResolving = false
    @Published private(set) var resolutionFailed = false

    let field: PlannerField

    private let service: TransitService
    private let places: PlacesStore?
    private let referenceCoordinate: GeoPoint?
    private let completer = AddressCompleterProxy()

    private var searchTask: Task<Void, Never>?
    /// The query the rider has actually typed. Anything that comes back tagged
    /// with a different one is stale and gets dropped on the floor.
    private var activeQuery = ""

    init(
        field: PlannerField,
        service: TransitService = .shared,
        places: PlacesStore? = nil,
        referenceCoordinate: GeoPoint? = nil
    ) {
        self.field = field
        self.service = service
        self.places = places
        self.referenceCoordinate = referenceCoordinate

        completer.onResults = { [weak self] query, suggestions in
            // The completer has no isolation of its own, so the hop is explicit.
            Task { @MainActor in
                self?.receiveAddresses(suggestions, for: query)
            }
        }
        reloadSavedPlaces(matching: "")
    }

    var showsCurrentLocation: Bool {
        activeQuery.isEmpty || String(localized: "My location").localizedCaseInsensitiveContains(activeQuery)
    }

    var currentLocationSuggestion: PlaceSuggestion {
        PlaceSuggestion(
            id: "current-location",
            source: .currentLocation,
            title: String(localized: "My location"),
            subtitle: String(localized: "Use where you are now"),
            endpoint: .currentLocation
        )
    }

    var isEmpty: Bool {
        savedPlaces.isEmpty && recents.isEmpty && stops.isEmpty && addresses.isEmpty && !showsCurrentLocation
    }

    var hasQuery: Bool { !activeQuery.isEmpty }

    // MARK: - Query

    func queryChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != activeQuery else { return }
        activeQuery = trimmed
        // Cancelling first is what stops a rider who edits twice from seeing the
        // first answer land on top of the second.
        searchTask?.cancel()
        resolutionFailed = false

        guard !trimmed.isEmpty else {
            completer.update(query: "", region: nil)
            stops = []
            addresses = []
            isSearching = false
            reloadSavedPlaces(matching: "")
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            // ~200 ms is about one keystroke at speed: long enough to avoid a
            // search per character, short enough that the list feels live.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, self.activeQuery == trimmed else { return }
            self.runSearch(trimmed)
        }
    }

    private func runSearch(_ text: String) {
        reloadSavedPlaces(matching: text)

        // The stop index is a linear scan over pre-folded bytes — well under a
        // millisecond even on a 40,000-stop feed — so it does not need to leave
        // the main actor, and going async would only add a frame of latency.
        let results = service.searchStops(text, near: referenceCoordinate, limit: 12)
        stops = results.map { result in
            // A label list, not a sentence — joining is safe to localise.
            var parts = [
                result.code.isEmpty
                    ? String(localized: "Stop")
                    : String(localized: "Stop \(result.code)"),
            ]
            if let distance = referenceCoordinate?.approximateDistance(to: result.coordinate) {
                parts.append(Format.distance(meters: distance))
            }
            let subtitle = parts.joined(separator: " · ")
            return PlaceSuggestion(
                id: "stop-\(result.stop)",
                source: .stop,
                title: result.name,
                subtitle: subtitle,
                endpoint: .stop(result.stop, name: result.name, coordinate: result.coordinate)
            )
        }

        completer.update(query: text, region: searchRegion)
        isSearching = false
    }

    private func receiveAddresses(_ suggestions: [PlaceSuggestion], for query: String) {
        guard query == activeQuery else { return }
        addresses = suggestions
    }

    private var searchRegion: MKCoordinateRegion? {
        guard let referenceCoordinate else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: referenceCoordinate.latitude,
                longitude: referenceCoordinate.longitude
            ),
            latitudinalMeters: 40_000,
            longitudinalMeters: 40_000
        )
    }

    // MARK: - Saved places

    private func reloadSavedPlaces(matching query: String) {
        let all = places?.places ?? []

        func matches(_ place: SavedPlace) -> Bool {
            query.isEmpty || place.name.localizedCaseInsensitiveContains(query)
        }

        // Home and work first, then the rest of the favourites alphabetically —
        // a favourites list that reorders itself is a favourites list nobody can
        // build muscle memory for. Ranking by an Int keeps the comparator a
        // strict weak ordering, which `sort` requires and traps without.
        let pinned = all.filter { $0.kind == .home || $0.kind == .work }
            .sorted { ($0.kind == .home ? 0 : 1) < ($1.kind == .home ? 0 : 1) }
        let favourites = all.filter { $0.kind == .favorite }
            .sorted { $0.name < $1.name }

        savedPlaces = (pinned + favourites)
            .filter(matches)
            .map(PlaceSearchViewModel.suggestion(for:))

        recents = all.filter { $0.kind == .recent }
            .filter(matches)
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(8)
            .map(PlaceSearchViewModel.suggestion(for:))
    }

    private static func suggestion(for place: SavedPlace) -> PlaceSuggestion {
        let endpoint: PlannerEndpoint
        if let stop = place.stop {
            endpoint = .stop(stop, name: place.name, coordinate: place.coordinate)
        } else {
            endpoint = .place(name: place.name, coordinate: place.coordinate)
        }
        let subtitle: String
        switch place.kind {
        case .home: subtitle = String(localized: "Home")
        case .work: subtitle = String(localized: "Work")
        case .favorite: subtitle = String(localized: "Favourite")
        case .recent: subtitle = String(localized: "Recent")
        }
        return PlaceSuggestion(
            id: "saved-\(place.id)",
            source: place.kind == .recent ? .recent : .saved(place.kind),
            title: place.name,
            subtitle: subtitle,
            endpoint: endpoint
        )
    }

    // MARK: - Selection

    /// Returns the endpoint to hand back, geocoding the row first if it needs it.
    func select(_ suggestion: PlaceSuggestion) async -> PlannerEndpoint? {
        if let endpoint = suggestion.endpoint {
            record(endpoint)
            return endpoint
        }

        guard suggestion.source == .address else { return nil }
        isResolving = true
        resolutionFailed = false
        defer { isResolving = false }

        let title = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let resolved: PlannerEndpoint? = await withCheckedContinuation { continuation in
            completer.resolve(id: suggestion.id, name: suggestion.title) { endpoint in
                continuation.resume(returning: endpoint)
            }
        }

        guard var resolved else {
            resolutionFailed = true
            return nil
        }
        resolved.name = title
        record(resolved)
        return resolved
    }

    /// Recents are how a planner stops being a typing exercise on day two.
    private func record(_ endpoint: PlannerEndpoint) {
        guard let places, let coordinate = endpoint.coordinate else { return }
        if case .currentLocation = endpoint.kind { return }

        var stop: StopIndex?
        if case .stop(let value) = endpoint.kind { stop = value }

        places.recordRecent(
            SavedPlace(
                id: "recent-\(endpoint.name)-\(coordinate.latitudeE6)-\(coordinate.longitudeE6)",
                kind: .recent,
                name: endpoint.name,
                coordinate: coordinate,
                stop: stop,
                // The GTFS id is what survives a feed rebuild, but nothing in the
                // presenter contract exposes it, so the index is stored alone and
                // re-resolved by name if it goes stale.
                stopIdentifier: nil,
                addedAt: Date()
            )
        )
    }

    #if DEBUG
    /// Previews only: fill the list without a graph or a network.
    func previewSet(saved: [PlaceSuggestion], recents: [PlaceSuggestion], stops: [PlaceSuggestion], addresses: [PlaceSuggestion]) {
        self.savedPlaces = saved
        self.recents = recents
        self.stops = stops
        self.addresses = addresses
    }
    #endif
}
