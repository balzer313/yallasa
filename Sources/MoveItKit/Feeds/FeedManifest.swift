import Foundation

/// A feed that has been compiled and is sitting on disk.
///
/// The graph is referenced by *file name*, never by absolute URL: on iOS the
/// container path changes between installs and OS upgrades, and a manifest full
/// of stale absolute paths is the classic way to lose a user's data without
/// actually deleting any of it.
public struct InstalledFeed: Codable, Hashable, Sendable, Identifiable {
    /// Matches `source.id`.
    public var id: String
    public var source: FeedSource
    /// File name inside the manager's `graphs` directory.
    public var graphFileName: String
    public var installedAt: Date
    public var metadata: GraphMetadata
    /// Size of the compiled graph. Shown in Settings and used for the disk budget.
    public var byteSize: Int64

    public init(
        id: String,
        source: FeedSource,
        graphFileName: String,
        installedAt: Date,
        metadata: GraphMetadata,
        byteSize: Int64
    ) {
        self.id = id
        self.source = source
        self.graphFileName = graphFileName
        self.installedAt = installedAt
        self.metadata = metadata
        self.byteSize = byteSize
    }

    /// True when the compiled graph predates the current on-disk format and must
    /// be rebuilt before it can be opened.
    public var needsRecompile: Bool { metadata.formatVersion != GraphFormat.version }

    // `GraphMetadata` is `Equatable` but not `Hashable`, so neither half of the
    // conformance can be synthesised here. Both are spelled out rather than
    // hashing a subset silently.

    public static func == (lhs: InstalledFeed, rhs: InstalledFeed) -> Bool {
        lhs.id == rhs.id
            && lhs.source == rhs.source
            && lhs.graphFileName == rhs.graphFileName
            && lhs.installedAt == rhs.installedAt
            && lhs.byteSize == rhs.byteSize
            && lhs.metadata == rhs.metadata
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(graphFileName)
        hasher.combine(installedAt)
        hasher.combine(byteSize)
        hasher.combine(source)
    }
}

/// Bookkeeping that belongs to an install but not to the graph: what the server
/// said about the archive last time, and what box the feed was clipped to.
///
/// Kept beside `InstalledFeed` rather than inside it so the shape of
/// `InstalledFeed` stays exactly what the rest of the app consumes, and so
/// refresh metadata can change without touching a type the UI binds to.
public struct FeedInstallRecord: Codable, Hashable, Sendable {
    /// `ETag` as the server sent it, quotes and any `W/` prefix included.
    public var entityTag: String?
    /// `Last-Modified` verbatim; compared as an opaque string rather than parsed,
    /// because we only ever ask "is it the same one".
    public var lastModified: String?
    public var contentLength: Int64?
    /// When the server was last asked whether the archive changed.
    public var checkedAt: Date
    /// When the archive currently on disk was fetched.
    public var downloadedAt: Date
    /// The clip box actually passed to the importer, so a recompile after a
    /// format bump reproduces the same graph without asking the user again.
    public var region: GeoBounds?
    public var archiveFileName: String?
    public var archiveByteSize: Int64

    public init(
        entityTag: String? = nil,
        lastModified: String? = nil,
        contentLength: Int64? = nil,
        checkedAt: Date = Date(),
        downloadedAt: Date = Date(),
        region: GeoBounds? = nil,
        archiveFileName: String? = nil,
        archiveByteSize: Int64 = 0
    ) {
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.contentLength = contentLength
        self.checkedAt = checkedAt
        self.downloadedAt = downloadedAt
        self.region = region
        self.archiveFileName = archiveFileName
        self.archiveByteSize = archiveByteSize
    }

    public var validators: FeedResourceValidators {
        FeedResourceValidators(entityTag: entityTag, lastModified: lastModified, contentLength: contentLength)
    }
}

/// The index of what is installed, stored as JSON next to the graphs.
///
/// The manifest — not the filesystem — is the source of truth. A graph file with
/// no manifest entry is garbage to be collected; a manifest entry with no graph
/// file is a bug worth surfacing. Keeping that direction fixed is what makes the
/// install sequence safe to interrupt: the manifest is written last, so a crash
/// anywhere before that leaves the previous state exactly as it was.
public struct FeedManifest: Codable, Sendable, Equatable {
    public static let fileName = "manifest.json"
    /// Bumped if the manifest's own shape changes incompatibly. Unknown future
    /// versions are treated as unreadable rather than misread.
    public static let currentVersion = 1

    public var version: Int
    public var feeds: [InstalledFeed]
    public var activeFeedID: String?
    public var installRecords: [String: FeedInstallRecord]

    public init(
        version: Int = FeedManifest.currentVersion,
        feeds: [InstalledFeed] = [],
        activeFeedID: String? = nil,
        installRecords: [String: FeedInstallRecord] = [:]
    ) {
        self.version = version
        self.feeds = feeds
        self.activeFeedID = activeFeedID
        self.installRecords = installRecords
    }

    public var isEmpty: Bool { feeds.isEmpty }

    public func feed(withID identifier: String) -> InstalledFeed? {
        feeds.first { $0.id == identifier }
    }

    /// Total size of the graphs the manifest knows about. Archives are counted
    /// separately because they are a cache, not user data.
    public var graphByteSize: Int64 {
        feeds.reduce(Int64(0)) { $0 + $1.byteSize }
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case version, feeds, activeFeedID, installRecords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? FeedManifest.currentVersion
        self.feeds = try container.decodeIfPresent([InstalledFeed].self, forKey: .feeds) ?? []
        self.activeFeedID = try container.decodeIfPresent(String.self, forKey: .activeFeedID)
        self.installRecords =
            try container.decodeIfPresent([String: FeedInstallRecord].self, forKey: .installRecords) ?? [:]
    }

    /// ISO-8601 dates so the file stays diffable and survives a locale change.
    /// The same strategy is used by the graph's own metadata section.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try FeedManifest.makeEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> FeedManifest {
        let manifest = try makeDecoder().decode(FeedManifest.self, from: data)
        guard manifest.version <= currentVersion else {
            throw FeedManifestError.unsupportedVersion(manifest.version)
        }
        return manifest
    }

    // MARK: - Persistence

    public static func load(from url: URL) throws -> FeedManifest {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }

    /// Loading must never be the reason the app cannot start. A missing file is
    /// the normal first-launch case, and a corrupt one is recoverable: the graphs
    /// are still on disk and the user can reinstall, whereas a crash loop is not
    /// recoverable at all.
    public static func loadOrEmpty(from url: URL) -> FeedManifest {
        (try? load(from: url)) ?? FeedManifest()
    }

    /// Writes the manifest so that a reader either sees the previous file in full
    /// or the new one in full.
    ///
    /// `Data.write(.atomic)` alone would be enough on its own, but it is not
    /// guaranteed to preserve the original file's metadata when replacing, and on
    /// iOS the data-protection class matters. Writing a sibling temp file and
    /// handing it to `replaceItemAt` gets both: an atomic rename and the
    /// original's attributes.
    public func save(to url: URL) throws {
        let data = try encoded()
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: [.atomic])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw FeedManifestError.writeFailed(String(describing: error))
        }
    }
}

public enum FeedManifestError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This feed library was written by a newer version of the app (format \(version))."
        case .writeFailed(let reason):
            return "The feed library could not be saved: \(reason)"
        }
    }
}
