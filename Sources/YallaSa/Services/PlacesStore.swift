import Foundation
import YallaSaKit

// MARK: - Saved place

/// A place the rider has told us about: home, work, a starred stop, or somewhere
/// they searched for recently.
///
/// Both a coordinate *and* a GTFS stop id are kept. The coordinate is what makes
/// the place useful at all — it still plans a trip after a feed swap — while the
/// id is what lets us re-point the place at the right `StopIndex` once a new
/// graph is compiled. Indices themselves are never trusted across a rebuild.
public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case home, work, favorite, recent
    }

    public var id: String
    public var kind: Kind
    public var name: String
    public var coordinate: GeoPoint
    /// Resolved lazily; may be stale after a feed swap until `PlacesStore.resolve(in:)` runs.
    public var stop: StopIndex?
    /// The GTFS id, which survives a feed swap.
    public var stopIdentifier: String?
    public var addedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        name: String,
        coordinate: GeoPoint,
        stop: StopIndex? = nil,
        stopIdentifier: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.coordinate = coordinate
        self.stop = stop
        self.stopIdentifier = stopIdentifier
        self.addedAt = addedAt
    }

    /// What counts as "the same place" for deduping recents.
    ///
    /// Stop-backed places compare by GTFS id; free coordinates compare at four
    /// decimal places, roughly 11 m. Without this, searching for home three
    /// times fills the recents list with home.
    var dedupeKey: String {
        if let stopIdentifier, !stopIdentifier.isEmpty { return "stop:\(stopIdentifier)" }
        return String(format: "geo:%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    public var symbolName: String {
        switch kind {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .favorite: return "star.fill"
        case .recent: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Store

/// Home, work, favourites and recents, persisted as JSON in Application Support.
///
/// Writes are synchronous and atomic. The document is a few kilobytes at the
/// 20-recent cap, so a write costs well under a millisecond — far cheaper than
/// the bookkeeping a background writer would need to guarantee that two rapid
/// toggles land on disk in the order the rider made them.
@MainActor
public final class PlacesStore: ObservableObject {
    @Published public private(set) var places: [SavedPlace] = []

    /// Recents past this count are dropped oldest-first. Saved places are never
    /// trimmed — the rider put them there on purpose.
    public static let recentLimit = 20

    private let fileName: String

    public init(fileName: String = "places.json") {
        self.fileName = fileName
        self.places = AppSupportStore.load([SavedPlace].self, from: fileName) ?? []
    }

    // MARK: Reading

    public var home: SavedPlace? { places.first { $0.kind == .home } }
    public var work: SavedPlace? { places.first { $0.kind == .work } }

    public var favorites: [SavedPlace] {
        places.filter { $0.kind == .favorite }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var recents: [SavedPlace] {
        places.filter { $0.kind == .recent }.sorted { $0.addedAt > $1.addedAt }
    }

    public func place(id: String) -> SavedPlace? {
        places.first { $0.id == id }
    }

    // MARK: Writing

    /// Adds or replaces a place.
    ///
    /// There is exactly one home and one work; adding a second replaces the
    /// first rather than leaving every consumer to guess which one is real.
    public func add(_ place: SavedPlace) {
        var updated = places
        if place.kind == .home || place.kind == .work {
            updated.removeAll { $0.kind == place.kind }
        } else {
            updated.removeAll { $0.id == place.id }
        }
        updated.append(place)
        places = updated
        persist()
    }

    public func remove(id: String) {
        guard places.contains(where: { $0.id == id }) else { return }
        places.removeAll { $0.id == id }
        persist()
    }

    public func removeAllRecents() {
        guard places.contains(where: { $0.kind == .recent }) else { return }
        places.removeAll { $0.kind == .recent }
        persist()
    }

    public func recordRecent(_ place: SavedPlace) {
        var recent = place
        recent.kind = .recent
        recent.addedAt = Date()

        var updated = places
        updated.removeAll { $0.kind == .recent && $0.dedupeKey == recent.dedupeKey }
        updated.append(recent)

        let ordered = updated.filter { $0.kind == .recent }.sorted { $0.addedAt > $1.addedAt }
        if ordered.count > PlacesStore.recentLimit {
            let doomed = Set(ordered.dropFirst(PlacesStore.recentLimit).map(\.id))
            updated.removeAll { doomed.contains($0.id) }
        }

        places = updated
        persist()
    }

    // MARK: Feed swaps

    /// Re-points every stop-backed place at the current graph.
    ///
    /// A place whose GTFS id has vanished keeps its coordinate and loses its
    /// index: the rider's "Home" is still their home even if the agency
    /// renumbered the stop outside their door, and the planner can route to a
    /// coordinate perfectly well. Only the index — the part that would silently
    /// point at a *different* stop — is dropped.
    public func resolve(in graph: TransitGraph) async {
        let wanted = Set(places.compactMap(\.stopIdentifier).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return }

        let resolved = await Task.detached(priority: .utility) {
            GraphIdentifierIndex.stopIndices(for: wanted, in: graph)
        }.value

        var updated = places
        var changed = false
        for index in updated.indices {
            guard let identifier = updated[index].stopIdentifier, !identifier.isEmpty else { continue }
            let newValue = resolved[identifier]
            if updated[index].stop != newValue {
                updated[index].stop = newValue
                changed = true
            }
        }
        guard changed else { return }
        places = updated
        persist()
    }

    private func persist() {
        AppSupportStore.save(places, to: fileName)
    }
}

// MARK: - Disk

/// Small JSON documents in Application Support.
///
/// Kept out of the feed directory deliberately: feeds are excluded from iCloud
/// backup because they are reproducible from the network, but a rider's home,
/// work and favourites are not reproducible and must survive a restore.
enum AppSupportStore {
    static let folderName = "YallaSa"

    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for fileName: String) throws -> URL {
        try directory().appendingPathComponent(fileName, isDirectory: false)
    }

    static func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        guard let url = try? url(for: fileName), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A corrupt document must not brick the app: fall back to "no saved
        // data" and let the next write replace it.
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to fileName: String) {
        guard let url = try? url(for: fileName) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        // `.atomic` writes to a sibling temp file and renames, so a crash mid-write
        // leaves the previous document intact rather than a truncated one.
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - GTFS id → index

/// Maps stored GTFS string ids onto the indices of a freshly compiled graph.
///
/// One linear pass per call rather than a full id→index dictionary: the sets we
/// resolve are tens of entries, while a feed has tens of thousands of stops, and
/// materialising every id as a `String` to build a map we would use twice is
/// strictly more work than scanning for the handful we care about.
enum GraphIdentifierIndex {
    static func stopIndices(for identifiers: Set<String>, in graph: TransitGraph) -> [String: StopIndex] {
        guard !identifiers.isEmpty else { return [:] }
        var result: [String: StopIndex] = [:]
        result.reserveCapacity(identifiers.count)
        for raw in 0..<graph.stopCount {
            let stop = StopIndex(raw)
            let identifier = graph.stopIdentifier(stop)
            guard identifiers.contains(identifier) else { continue }
            result[identifier] = stop
            if result.count == identifiers.count { break }
        }
        return result
    }

    static func routeIndices(for identifiers: Set<String>, in graph: TransitGraph) -> [String: RouteIndex] {
        guard !identifiers.isEmpty else { return [:] }
        var result: [String: RouteIndex] = [:]
        result.reserveCapacity(identifiers.count)
        for raw in 0..<graph.routeCount {
            let route = RouteIndex(raw)
            let identifier = graph.routeIdentifier(route)
            guard identifiers.contains(identifier) else { continue }
            result[identifier] = route
            if result.count == identifiers.count { break }
        }
        return result
    }
}
