import Foundation
import YallaSaKit

/// Starred lines and stops.
///
/// Only GTFS string ids are persisted. A `RouteIndex` is a position in a
/// columnar array that the importer rebuilds from scratch on every refresh — a
/// favourite stored as `route 417` would, after an update, cheerfully point at
/// whatever line happens to land in slot 417 next time. A favourite that quietly
/// becomes a different bus is worse than no favourite at all.
///
/// The index sets are a cache derived from those ids, refreshed by
/// `resolve(in:)` whenever a graph is activated, and kept in step on toggle by
/// the caller passing the index it already has in hand.
@MainActor
public final class FavoriteLinesStore: ObservableObject {
    @Published public private(set) var routeIdentifiers: Set<String> = []
    @Published public private(set) var stopIdentifiers: Set<String> = []

    /// Derived from the identifiers against the active graph. Empty until
    /// `resolve(in:)` has run for the current feed.
    @Published public private(set) var routeIndices: Set<RouteIndex> = []
    @Published public private(set) var stopIndices: Set<StopIndex> = []

    private struct Document: Codable {
        var routes: [String] = []
        var stops: [String] = []
    }

    private let fileName: String

    public init(fileName: String = "favorites.json") {
        self.fileName = fileName
        let document = AppSupportStore.load(Document.self, from: fileName)
        self.routeIdentifiers = Set(document?.routes ?? [])
        self.stopIdentifiers = Set(document?.stops ?? [])
    }

    // MARK: Reading

    public func containsRoute(_ gtfsID: String) -> Bool { routeIdentifiers.contains(gtfsID) }
    public func containsStop(_ gtfsID: String) -> Bool { stopIdentifiers.contains(gtfsID) }

    public func containsRoute(index: RouteIndex) -> Bool { routeIndices.contains(index) }
    public func containsStop(index: StopIndex) -> Bool { stopIndices.contains(index) }

    public var isEmpty: Bool { routeIdentifiers.isEmpty && stopIdentifiers.isEmpty }

    // MARK: Writing

    /// Toggles a line.
    ///
    /// `index` is optional so the pinned `toggleRoute(_:)` signature still
    /// compiles; passing it lets the derived index set update immediately
    /// instead of waiting for the next `resolve(in:)`, which is what makes a
    /// star fill in the same frame it was tapped.
    public func toggleRoute(_ gtfsID: String, index: RouteIndex? = nil) {
        guard !gtfsID.isEmpty else { return }
        if routeIdentifiers.contains(gtfsID) {
            routeIdentifiers.remove(gtfsID)
            if let index { routeIndices.remove(index) }
        } else {
            routeIdentifiers.insert(gtfsID)
            if let index { routeIndices.insert(index) }
        }
        persist()
    }

    public func toggleStop(_ gtfsID: String, index: StopIndex? = nil) {
        guard !gtfsID.isEmpty else { return }
        if stopIdentifiers.contains(gtfsID) {
            stopIdentifiers.remove(gtfsID)
            if let index { stopIndices.remove(index) }
        } else {
            stopIdentifiers.insert(gtfsID)
            if let index { stopIndices.insert(index) }
        }
        persist()
    }

    public func removeAll() {
        guard !isEmpty else { return }
        routeIdentifiers = []
        stopIdentifiers = []
        routeIndices = []
        stopIndices = []
        persist()
    }

    // MARK: Feed swaps

    /// Re-resolves every stored id against a freshly compiled graph and drops
    /// the ones the feed no longer contains.
    ///
    /// Unlike a saved place, a favourite line has nothing useful left once its
    /// id is gone — there is no coordinate to fall back on — so a discontinued
    /// route is removed rather than kept as a dead row.
    public func resolve(in graph: TransitGraph) async {
        let wantedRoutes = routeIdentifiers
        let wantedStops = stopIdentifiers
        guard !wantedRoutes.isEmpty || !wantedStops.isEmpty else {
            routeIndices = []
            stopIndices = []
            return
        }

        let resolved = await Task.detached(priority: .utility) { () -> (routes: [String: RouteIndex], stops: [String: StopIndex]) in
            (
                GraphIdentifierIndex.routeIndices(for: wantedRoutes, in: graph),
                GraphIdentifierIndex.stopIndices(for: wantedStops, in: graph)
            )
        }.value

        let survivingRoutes = Set(resolved.routes.keys)
        let survivingStops = Set(resolved.stops.keys)

        routeIndices = Set(resolved.routes.values)
        stopIndices = Set(resolved.stops.values)

        guard survivingRoutes != routeIdentifiers || survivingStops != stopIdentifiers else { return }
        routeIdentifiers = survivingRoutes
        stopIdentifiers = survivingStops
        persist()
    }

    private func persist() {
        AppSupportStore.save(
            Document(routes: routeIdentifiers.sorted(), stops: stopIdentifiers.sorted()),
            to: fileName
        )
    }
}
