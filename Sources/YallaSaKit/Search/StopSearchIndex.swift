import Foundation

/// Fuzzy-ish stop search over a graph.
///
/// Built lazily and kept for the life of a graph. The index is a flat array of
/// normalised names rather than a trie: for a 40,000-stop feed a linear scan of
/// pre-folded byte strings runs in well under a millisecond, which is faster
/// than a keystroke, and it avoids the memory and build cost of a real index for
/// no perceptible gain.
///
/// Normalisation folds case and diacritics, so "Hadera" matches "Ḥadera" and
/// "koln" matches "Köln" — a rider typing on a phone keyboard should not have to
/// produce the exact glyphs the agency used.
public final class StopSearchIndex: @unchecked Sendable {
    /// One searchable row. Platforms are folded into their parent station so a
    /// search for a big interchange returns one result, not twenty.
    public struct Entry: Sendable {
        public let stop: StopIndex
        public let name: String
        public let code: String
        public let coordinate: GeoPoint
        /// Number of distinct patterns serving the stop, used to rank busy
        /// interchanges above minor ones with similar names.
        public let importance: Int
        let normalisedName: [UInt8]
        let normalisedCode: [UInt8]
    }

    public struct Result: Sendable, Identifiable {
        public let stop: StopIndex
        public let name: String
        public let code: String
        public let coordinate: GeoPoint
        public let score: Int
        public var id: StopIndex { stop }
    }

    private let entries: [Entry]

    public init(graph: TransitGraph) {
        var built: [Entry] = []
        built.reserveCapacity(graph.stopCount)

        // Collapse platforms into stations, keeping the station's own record when
        // the feed provides one and otherwise promoting the first child.
        var representativeByStation: [StopIndex: Int] = [:]
        representativeByStation.reserveCapacity(graph.stopCount)

        for rawIndex in 0..<graph.stopCount {
            let stop = StopIndex(rawIndex)
            let name = graph.stopName(stop)
            guard !name.isEmpty else { continue }

            let patternCount = graph.patternSlots(atStop: stop).count
            // A station record has no patterns of its own; keep it only if it is
            // the anchor for children that do.
            let station = graph.stopStation(stop)

            let entry = Entry(
                stop: stop,
                name: name,
                code: graph.stopCode(stop),
                coordinate: graph.stopCoordinate(stop),
                importance: patternCount,
                normalisedName: StopSearchIndex.normalise(name),
                normalisedCode: StopSearchIndex.normalise(graph.stopCode(stop))
            )

            if let existingSlot = representativeByStation[station] {
                // Prefer the station record itself; otherwise the busiest child.
                let existing = built[existingSlot]
                let candidateIsStation = graph.stopIsStation(stop)
                let existingIsStation = graph.stopIsStation(existing.stop)
                let replaces = (candidateIsStation && !existingIsStation)
                    || (candidateIsStation == existingIsStation && entry.importance > existing.importance)
                if replaces {
                    built[existingSlot] = Entry(
                        stop: entry.stop,
                        name: entry.name,
                        code: entry.code,
                        coordinate: entry.coordinate,
                        importance: existing.importance + entry.importance,
                        normalisedName: entry.normalisedName,
                        normalisedCode: entry.normalisedCode
                    )
                } else {
                    built[existingSlot] = Entry(
                        stop: existing.stop,
                        name: existing.name,
                        code: existing.code,
                        coordinate: existing.coordinate,
                        importance: existing.importance + entry.importance,
                        normalisedName: existing.normalisedName,
                        normalisedCode: existing.normalisedCode
                    )
                }
            } else {
                representativeByStation[station] = built.count
                built.append(entry)
            }
        }

        self.entries = built
    }

    public var count: Int { entries.count }

    /// Ranked matches for a query.
    ///
    /// `near` biases results toward the rider: two stops called "Central Station"
    /// in one feed are disambiguated by which one you are standing next to.
    public func search(_ query: String, near origin: GeoPoint? = nil, limit: Int = 25) -> [Result] {
        let needle = StopSearchIndex.normalise(query)
        guard !needle.isEmpty else { return [] }

        var results: [Result] = []
        results.reserveCapacity(min(limit * 4, 128))

        for entry in entries {
            guard var score = StopSearchIndex.score(needle: needle, haystack: entry.normalisedName) else {
                // A rider who types a stop code expects the stop, so codes are a
                // fallback match rather than a separate search mode.
                if StopSearchIndex.matchesExactly(needle: needle, haystack: entry.normalisedCode) {
                    results.append(
                        Result(
                            stop: entry.stop, name: entry.name, code: entry.code,
                            coordinate: entry.coordinate, score: 900
                        )
                    )
                }
                continue
            }

            score += min(entry.importance, 40)

            if let origin {
                let distance = origin.approximateDistance(to: entry.coordinate)
                // Full bonus under 1 km, decaying to nothing by 30 km. Deliberately
                // gentle: proximity should break ties, not override a better name.
                score += Int(max(0, 60 - distance / 500))
            }

            results.append(
                Result(
                    stop: entry.stop, name: entry.name, code: entry.code,
                    coordinate: entry.coordinate, score: score
                )
            )
        }

        results.sort {
            $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score
        }
        if results.count > limit { results.removeSubrange(limit...) }
        return results
    }

    // MARK: - Matching

    /// Higher is better; `nil` means no match at all.
    static func score(needle: [UInt8], haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }

        if hasPrefix(haystack, needle) {
            return haystack.count == needle.count ? 1000 : 800
        }
        // Match at the start of any word: "central" should find "Tel Aviv Central".
        var index = 0
        while index < haystack.count - needle.count {
            if haystack[index] == UInt8(ascii: " "), hasPrefix(haystack, needle, from: index + 1) {
                return 600
            }
            index += 1
        }
        if contains(haystack, needle) { return 300 }
        return nil
    }

    static func matchesExactly(needle: [UInt8], haystack: [UInt8]) -> Bool {
        !haystack.isEmpty && needle == haystack
    }

    static func hasPrefix(_ haystack: [UInt8], _ needle: [UInt8], from start: Int = 0) -> Bool {
        guard start + needle.count <= haystack.count else { return false }
        for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
            return false
        }
        return true
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            if hasPrefix(haystack, needle, from: start) { return true }
            start += 1
        }
        return false
    }

    /// Case- and diacritic-folded UTF-8, with runs of whitespace and punctuation
    /// collapsed to single spaces so "St. Paul's" and "St Pauls" agree.
    static func normalise(_ value: String) -> [UInt8] {
        guard !value.isEmpty else { return [] }
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        var bytes: [UInt8] = []
        bytes.reserveCapacity(folded.utf8.count)
        var lastWasSeparator = true
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic || (scalar.value >= 48 && scalar.value <= 57) {
                for byte in String(scalar).utf8 { bytes.append(byte) }
                lastWasSeparator = false
            } else if !lastWasSeparator {
                bytes.append(UInt8(ascii: " "))
                lastWasSeparator = true
            }
        }
        while bytes.last == UInt8(ascii: " ") { bytes.removeLast() }
        return bytes
    }
}
