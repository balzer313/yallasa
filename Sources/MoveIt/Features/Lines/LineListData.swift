import Foundation
import MoveItKit

// MARK: - Mode naming

/// Human names for a `TransitMode`.
///
/// `TransitMode.localizedNameKey` gives a key, not a string, and the same mode
/// is needed in the singular ("Bus 42") and the plural ("Buses") in different
/// places, so both live here rather than being reinvented per screen.
enum TransitModeNaming {
    static func title(_ mode: TransitMode) -> String {
        switch mode {
        case .tram: return String(localized: "Tram")
        case .subway: return String(localized: "Metro")
        case .rail: return String(localized: "Train")
        case .bus: return String(localized: "Bus")
        case .ferry: return String(localized: "Ferry")
        case .cableTram: return String(localized: "Cable tram")
        case .aerialLift: return String(localized: "Cable car")
        case .funicular: return String(localized: "Funicular")
        case .trolleybus: return String(localized: "Trolleybus")
        case .monorail: return String(localized: "Monorail")
        case .taxi: return String(localized: "Shared taxi")
        case .other: return String(localized: "Line")
        }
    }

    static func sectionTitle(_ mode: TransitMode) -> String {
        switch mode {
        case .tram: return String(localized: "Trams")
        case .subway: return String(localized: "Metro")
        case .rail: return String(localized: "Trains")
        case .bus: return String(localized: "Buses")
        case .ferry: return String(localized: "Ferries")
        case .cableTram: return String(localized: "Cable trams")
        case .aerialLift: return String(localized: "Cable cars")
        case .funicular: return String(localized: "Funiculars")
        case .trolleybus: return String(localized: "Trolleybuses")
        case .monorail: return String(localized: "Monorail")
        case .taxi: return String(localized: "Shared taxis")
        case .other: return String(localized: "Other lines")
        }
    }
}

// MARK: - Line list

/// One row in the line browser.
///
/// Everything a row draws is resolved once, off the main actor, when the feed is
/// loaded. Nothing here reaches back into the graph, so the list survives a feed
/// swap mid-scroll and can be previewed from literals.
struct LineListItem: Identifiable, Hashable, Sendable {
    var route: RouteIndex
    /// The GTFS id, which is what favourites are keyed on.
    var routeIdentifier: String
    var badge: LineBadgeData
    var longName: String
    var agencyName: String
    var mode: TransitMode
    var patternCount: Int
    /// Case- and diacritic-folded `badge · long name · agency`, built once so a
    /// keystroke costs a substring scan rather than thousands of `folding` calls.
    var searchKey: String

    var id: RouteIndex { route }

    /// One composed VoiceOver sentence for the whole row.
    var accessibilityLabel: String {
        var parts: [String] = [badge.accessibilityLabel]
        if !longName.isEmpty, longName != badge.text { parts.append(longName) }
        if !agencyName.isEmpty { parts.append(agencyName) }
        return parts.joined(separator: ", ")
    }
}

struct LineGroup: Identifiable, Hashable, Sendable {
    var mode: TransitMode
    var lines: [LineListItem]

    var id: TransitMode { mode }
    var title: String { TransitModeNaming.sectionTitle(mode) }
}

extension LineListItem {
    /// Folds a string the way `searchKey` is folded, so query and haystack agree
    /// on case and diacritics ("koln" finds "Köln").
    static func fold(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the whole browser from a graph.
    ///
    /// This walks every pattern and every route in the feed — tens of thousands
    /// of iterations on a metro-sized import — so it is `nonisolated` and only
    /// ever called from a detached task. The result is immutable value types,
    /// which is what makes it safe to hand back to the main actor.
    nonisolated static func build(from graph: TransitGraph) -> [LineListItem] {
        let routeCount = graph.routeCount
        guard routeCount > 0 else { return [] }

        // A route with no pattern has no trips inside the compiled calendar
        // window. Showing it would give the rider a line that opens onto an
        // empty timetable, which reads as a bug rather than as "not running".
        var patternCounts = [Int](repeating: 0, count: routeCount)
        for rawPattern in 0..<graph.patternCount {
            let route = graph.patternRoute(PatternIndex(rawPattern))
            guard route >= 0, Int(route) < routeCount else { continue }
            patternCounts[Int(route)] += 1
        }

        var items: [LineListItem] = []
        items.reserveCapacity(routeCount)

        for raw in 0..<routeCount {
            guard patternCounts[raw] > 0 else { continue }
            let route = RouteIndex(raw)

            let displayName = graph.routeDisplayName(route)
            guard !displayName.isEmpty else { continue }

            let longName = graph.routeLongName(route)
            let mode = graph.routeMode(route)
            let agency = graph.agencyName(graph.routeAgency(route))

            let badge = LineBadgeData(
                text: displayName,
                backgroundHex: graph.routeColor(route),
                foregroundHex: graph.routeTextColor(route),
                mode: mode,
                accessibilityLabel: "\(TransitModeNaming.title(mode)) \(displayName)"
            )

            items.append(
                LineListItem(
                    route: route,
                    routeIdentifier: graph.routeIdentifier(route),
                    badge: badge,
                    longName: longName,
                    agencyName: agency,
                    mode: mode,
                    patternCount: patternCounts[raw],
                    searchKey: fold("\(displayName) \(longName) \(agency)")
                )
            )
        }

        // `localizedStandardCompare` orders 1, 2, 10 rather than 1, 10, 2, which
        // is the only ordering a rider looking for the 10 will accept.
        items.sort { left, right in
            let comparison = left.badge.text.localizedStandardCompare(right.badge.text)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return left.longName.localizedStandardCompare(right.longName) == .orderedAscending
        }
        return items
    }
}
