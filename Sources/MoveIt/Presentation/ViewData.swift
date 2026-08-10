import Foundation
import MoveItKit

/// Plain data the views render.
///
/// Nothing here holds a reference to the graph, a service or a task. That is the
/// whole point: a view built from these structs can be previewed, snapshotted and
/// unit-tested without a compiled feed, and a feed swap mid-render cannot pull an
/// index out from under a row that is already on screen.
///
/// All of these are `Sendable` because they are produced on the main actor from
/// results that crossed back from the engine's queue, and `Hashable` because
/// SwiftUI navigation values and `ForEach` identity both want it.

// MARK: - Line badge

public struct LineBadgeData: Hashable, Sendable {
    public var text: String            // "42", "M14", "Red Line"
    public var backgroundHex: UInt32
    public var foregroundHex: UInt32
    public var mode: TransitMode
    public var accessibilityLabel: String   // "Bus 42"

    public init(
        text: String,
        backgroundHex: UInt32,
        foregroundHex: UInt32,
        mode: TransitMode,
        accessibilityLabel: String
    ) {
        self.text = text
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.mode = mode
        self.accessibilityLabel = accessibilityLabel
    }
}

// MARK: - Departures

public struct DepartureItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var badge: LineBadgeData
    public var headsign: String
    public var stop: StopIndex
    public var stopName: String
    public var stopCode: String
    public var pattern: PatternIndex
    public var trip: TripIndex
    public var position: Int
    /// Seconds from midnight of `queryDate`, realtime already applied.
    public var departureSeconds: ServiceSeconds
    public var scheduledSeconds: ServiceSeconds
    public var queryDate: ServiceDate
    public var status: LiveStatus
    public var walkMeters: Double?      // distance from the user, when known

    public init(
        id: String,
        badge: LineBadgeData,
        headsign: String,
        stop: StopIndex,
        stopName: String,
        stopCode: String,
        pattern: PatternIndex,
        trip: TripIndex,
        position: Int,
        departureSeconds: ServiceSeconds,
        scheduledSeconds: ServiceSeconds,
        queryDate: ServiceDate,
        status: LiveStatus,
        walkMeters: Double?
    ) {
        self.id = id
        self.badge = badge
        self.headsign = headsign
        self.stop = stop
        self.stopName = stopName
        self.stopCode = stopCode
        self.pattern = pattern
        self.trip = trip
        self.position = position
        self.departureSeconds = departureSeconds
        self.scheduledSeconds = scheduledSeconds
        self.queryDate = queryDate
        self.status = status
        self.walkMeters = walkMeters
    }
}

// MARK: - Stops

public struct StopItem: Identifiable, Hashable, Sendable {
    public var id: StopIndex
    public var stop: StopIndex
    public var name: String
    public var code: String
    public var coordinate: GeoPoint
    public var distanceMeters: Double?
    public var lines: [LineBadgeData]   // deduped, capped at 8 by the presenter
    public var accessibility: AccessibilityFlag

    public init(
        id: StopIndex,
        stop: StopIndex,
        name: String,
        code: String,
        coordinate: GeoPoint,
        distanceMeters: Double?,
        lines: [LineBadgeData],
        accessibility: AccessibilityFlag
    ) {
        self.id = id
        self.stop = stop
        self.name = name
        self.code = code
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
        self.lines = lines
        self.accessibility = accessibility
    }
}

// MARK: - Journeys

public struct JourneyLegItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case walk, ride }
    public var id: String
    public var kind: Kind
    public var badge: LineBadgeData?     // ride only
    public var headsign: String
    public var fromName: String
    public var toName: String
    public var fromStop: StopIndex?
    public var toStop: StopIndex?
    public var departureSeconds: ServiceSeconds
    public var arrivalSeconds: ServiceSeconds
    public var status: LiveStatus
    public var distanceMeters: Double    // walk only
    public var intermediateStopCount: Int
    public var intermediateStopNames: [String]

    public init(
        id: String,
        kind: Kind,
        badge: LineBadgeData?,
        headsign: String,
        fromName: String,
        toName: String,
        fromStop: StopIndex?,
        toStop: StopIndex?,
        departureSeconds: ServiceSeconds,
        arrivalSeconds: ServiceSeconds,
        status: LiveStatus,
        distanceMeters: Double,
        intermediateStopCount: Int,
        intermediateStopNames: [String]
    ) {
        self.id = id
        self.kind = kind
        self.badge = badge
        self.headsign = headsign
        self.fromName = fromName
        self.toName = toName
        self.fromStop = fromStop
        self.toStop = toStop
        self.departureSeconds = departureSeconds
        self.arrivalSeconds = arrivalSeconds
        self.status = status
        self.distanceMeters = distanceMeters
        self.intermediateStopCount = intermediateStopCount
        self.intermediateStopNames = intermediateStopNames
    }

    public var durationSeconds: Int32 { arrivalSeconds - departureSeconds }
}

public struct JourneyItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var journey: Journey          // kept for re-selection and detail
    public var legs: [JourneyLegItem]
    public var departureSeconds: ServiceSeconds
    public var arrivalSeconds: ServiceSeconds
    public var baseDate: ServiceDate
    public var durationSeconds: Int32
    public var transferCount: Int
    public var walkMeters: Double
    public var badges: [LineBadgeData]   // the ride sequence, for the summary strip
    public var isWalkOnly: Bool
    public var hasRealtime: Bool

    public init(
        id: String,
        journey: Journey,
        legs: [JourneyLegItem],
        departureSeconds: ServiceSeconds,
        arrivalSeconds: ServiceSeconds,
        baseDate: ServiceDate,
        durationSeconds: Int32,
        transferCount: Int,
        walkMeters: Double,
        badges: [LineBadgeData],
        isWalkOnly: Bool,
        hasRealtime: Bool
    ) {
        self.id = id
        self.journey = journey
        self.legs = legs
        self.departureSeconds = departureSeconds
        self.arrivalSeconds = arrivalSeconds
        self.baseDate = baseDate
        self.durationSeconds = durationSeconds
        self.transferCount = transferCount
        self.walkMeters = walkMeters
        self.badges = badges
        self.isWalkOnly = isWalkOnly
        self.hasRealtime = hasRealtime
    }
}

// MARK: - Patterns

public struct PatternItem: Identifiable, Hashable, Sendable {
    public var id: PatternIndex
    public var pattern: PatternIndex
    public var route: RouteIndex
    public var badge: LineBadgeData
    public var headsign: String
    public var stopCount: Int
    public var direction: UInt8

    public init(
        id: PatternIndex,
        pattern: PatternIndex,
        route: RouteIndex,
        badge: LineBadgeData,
        headsign: String,
        stopCount: Int,
        direction: UInt8
    ) {
        self.id = id
        self.pattern = pattern
        self.route = route
        self.badge = badge
        self.headsign = headsign
        self.stopCount = stopCount
        self.direction = direction
    }
}

// MARK: - Day-frame arithmetic

public extension DepartureItem {
    /// Seconds until this departure, measured in the same day frame the item's
    /// times live in.
    ///
    /// Naively using "seconds since local midnight" breaks at exactly the moment
    /// a rider is most likely to be staring at the screen: a board loaded at
    /// 23:58 keeps ticking past midnight, and without folding the day difference
    /// back in, every countdown would jump forward by 24 hours.
    func secondsUntilDeparture(at date: Date, in timeZone: TimeZone) -> Int32 {
        departureSeconds - DepartureItem.nowSeconds(for: queryDate, at: date, in: timeZone)
    }

    /// "Now", expressed as seconds past midnight of `queryDate`.
    static func nowSeconds(for queryDate: ServiceDate, at date: Date, in timeZone: TimeZone) -> ServiceSeconds {
        let instant = ServiceInstant(date: date, in: timeZone)
        let dayDelta = instant.date.days(since: queryDate)
        return instant.seconds + ServiceSeconds(clamping: dayDelta * 86_400)
    }
}

// MARK: - LiveStatus hashing

/// `LiveStatus` is declared `Equatable` in `Theme.swift`, but `DepartureItem`,
/// `JourneyLegItem` and therefore `AppDestination.journey` all need `Hashable` to
/// be usable as SwiftUI navigation values. Synthesis only happens in the type's
/// own file, so the witness is written out here rather than by editing the theme.
extension LiveStatus: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .scheduled:
            hasher.combine(0)
        case .onTime:
            hasher.combine(1)
        case .late(let seconds):
            hasher.combine(2)
            hasher.combine(seconds)
        case .early(let seconds):
            hasher.combine(3)
            hasher.combine(seconds)
        case .cancelled:
            hasher.combine(4)
        }
    }
}
