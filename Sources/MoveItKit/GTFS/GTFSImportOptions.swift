import Foundation

/// Everything the compiler needs that is not in the archive itself.
///
/// The identity fields are carried straight into `GraphMetadata` so a graph file
/// can always say where it came from; `boundingBox` and `calendarWindow` exist
/// because a national feed compiled whole is an order of magnitude larger than
/// the city a rider actually uses it in.
public struct GTFSImportOptions: Sendable {
    public var feedIdentifier: String
    public var feedName: String
    public var sourceURL: String
    public var buildOptions: GraphMetadata.BuildOptions

    /// Clip the feed to a region. Nil imports everything.
    public var boundingBox: GeoBounds?

    /// Service days to keep. Nil keeps the feed's own range, capped at 400 days.
    public var calendarWindow: ClosedRange<ServiceDate>?

    public init(feedIdentifier: String, feedName: String, sourceURL: String) {
        self.feedIdentifier = feedIdentifier
        self.feedName = feedName
        self.sourceURL = sourceURL
        self.buildOptions = GraphMetadata.BuildOptions()
        self.boundingBox = nil
        self.calendarWindow = nil
    }
}

/// Coarse stages of a compile, in the order they run.
///
/// The UI shows the phase name rather than a bare percentage because the phases
/// have wildly different durations — `stopTimes` is most of a large import — and
/// a progress bar that sits at 40% for a minute reads as a hang.
public enum GTFSImportPhase: String, Sendable, CaseIterable {
    case openingArchive, agencies, stops, routes, calendar, trips, stopTimes,
         buildingPatterns, buildingTransfers, buildingIndex, writing, verifying
}

public struct GTFSImportProgress: Sendable {
    public var phase: GTFSImportPhase
    /// 0...1 within the phase.
    public var fractionCompleted: Double
    /// 0...1 across the whole import.
    public var overallFraction: Double
    public var detail: String

    public init(phase: GTFSImportPhase, fractionCompleted: Double, overallFraction: Double, detail: String) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.overallFraction = overallFraction
        self.detail = detail
    }
}

public enum GTFSImportError: Error, LocalizedError, Equatable {
    case missingRequiredFile(String)
    case noUsableStops
    case noUsableTrips
    case cancelled
    case archive(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredFile(let name):
            return "The feed is missing \(name), which GTFS requires."
        case .noUsableStops:
            return "The feed contains no stops with usable coordinates."
        case .noUsableTrips:
            return "The feed contains no trips that run on any day in range."
        case .cancelled:
            return "The import was cancelled."
        case .archive(let reason):
            return "The feed archive could not be read: \(reason)."
        }
    }
}
