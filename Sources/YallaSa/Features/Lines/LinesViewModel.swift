import Foundation
import Combine
import YallaSaKit

/// Drives the line browser.
///
/// The expensive half of this screen is one full pass over the feed's routes and
/// patterns. It runs once per graph in a detached task, lands as an immutable
/// array, and is then filtered in place: typing a character re-scans a few
/// thousand pre-folded strings, which is microseconds, rather than re-reading
/// the graph.
@MainActor
final class LinesViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case noFeed
        case empty
        case error(String)
        case content
    }

    @Published private(set) var phase: Phase = .loading
    /// Starred lines, pinned above everything and excluded from the mode groups
    /// so a favourite never appears twice.
    @Published private(set) var favoriteLines: [LineListItem] = []
    @Published private(set) var groups: [LineGroup] = []
    @Published var query: String = ""
    @Published private(set) var totalLineCount: Int = 0
    @Published private(set) var matchCount: Int = 0

    private var allLines: [LineListItem] = []
    private var favoriteIdentifiers: Set<String> = []
    /// Identity of the graph the cache was built from. A feed swap hands us a
    /// different object, which is the only reliable signal that indices moved.
    private var loadedGraphToken: ObjectIdentifier?
    private var buildTask: Task<Void, Never>?

    deinit { buildTask?.cancel() }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasResults: Bool { !favoriteLines.isEmpty || groups.contains { !$0.lines.isEmpty } }

    // MARK: - Loading

    func load(service: TransitService, favorites: FavoriteLinesStore, force: Bool = false) {
        favoriteIdentifiers = favorites.routeIdentifiers

        guard let graph = service.graph else {
            buildTask?.cancel()
            allLines = []
            groups = []
            favoriteLines = []
            loadedGraphToken = nil
            totalLineCount = 0
            matchCount = 0
            switch service.state {
            case .failed(let message): phase = .error(message)
            case .needsFeed: phase = .noFeed
            case .idle, .installing, .ready: phase = .loading
            }
            return
        }

        let token = ObjectIdentifier(graph)
        if !force, token == loadedGraphToken, !allLines.isEmpty {
            applyFilter()
            return
        }

        buildTask?.cancel()
        phase = .loading
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                LineListItem.build(from: graph)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.allLines = built
            self.loadedGraphToken = token
            self.totalLineCount = built.count
            self.applyFilter()
            self.phase = built.isEmpty ? .empty : .content
        }
    }

    func updateFavorites(_ identifiers: Set<String>) {
        guard identifiers != favoriteIdentifiers else { return }
        favoriteIdentifiers = identifiers
        guard !allLines.isEmpty else { return }
        applyFilter()
    }

    // MARK: - Filtering

    func applyFilter() {
        let needle = LineListItem.fold(query)
        let filtered = needle.isEmpty ? allLines : allLines.filter { $0.searchKey.contains(needle) }
        matchCount = filtered.count

        let starred = filtered.filter { favoriteIdentifiers.contains($0.routeIdentifier) }
        favoriteLines = starred

        let starredRoutes = Set(starred.map(\.route))
        var buckets: [TransitMode: [LineListItem]] = [:]
        for line in filtered where !starredRoutes.contains(line.route) {
            buckets[line.mode, default: []].append(line)
        }

        groups = buckets
            .map { LineGroup(mode: $0.key, lines: $0.value) }
            .sorted { left, right in
                if left.mode.displayPriority != right.mode.displayPriority {
                    return left.mode.displayPriority < right.mode.displayPriority
                }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }
}
