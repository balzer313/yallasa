import Foundation
import SwiftUI
import YallaSaKit

// MARK: - Endpoint

/// One end of a planned trip, as the *UI* understands it.
///
/// The engine only knows `PlanEndpoint` — a stop index or a coordinate — but the
/// screen has to keep more: a name to draw, and the fact that "My location" is a
/// promise to be resolved at plan time rather than a fixed point. Resolving it
/// eagerly would freeze the rider's position at the moment they opened the
/// screen, which is wrong for a planner they may leave open for ten minutes.
public struct PlannerEndpoint: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case currentLocation
        case stop(StopIndex)
        case coordinate
    }

    public var kind: Kind
    public var name: String
    public var coordinate: GeoPoint?
    /// Resolved for the engine. `nil` for `.currentLocation` until a fix arrives.
    public var planEndpoint: PlanEndpoint?

    public init(
        kind: Kind,
        name: String,
        coordinate: GeoPoint? = nil,
        planEndpoint: PlanEndpoint? = nil
    ) {
        self.kind = kind
        self.name = name
        self.coordinate = coordinate
        self.planEndpoint = planEndpoint
    }

    public static let currentLocation = PlannerEndpoint(
        kind: .currentLocation,
        name: String(localized: "My location")
    )

    public static func stop(_ stop: StopIndex, name: String, coordinate: GeoPoint?) -> PlannerEndpoint {
        PlannerEndpoint(kind: .stop(stop), name: name, coordinate: coordinate, planEndpoint: .stop(stop))
    }

    public static func place(name: String, coordinate: GeoPoint) -> PlannerEndpoint {
        PlannerEndpoint(
            kind: .coordinate,
            name: name,
            coordinate: coordinate,
            planEndpoint: .coordinate(coordinate)
        )
    }

    /// True when the endpoint can already be handed to the router.
    public var isResolved: Bool { planEndpoint != nil }

    public var symbolName: String {
        switch kind {
        case .currentLocation: return "location.fill"
        case .stop: return "signpost.right.fill"
        case .coordinate: return "mappin.circle.fill"
        }
    }
}

// MARK: - Time control

public enum PlannerTimeMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    case leaveNow
    case leaveAt
    case arriveBy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leaveNow: return String(localized: "Leave now")
        case .leaveAt: return String(localized: "Leave at")
        case .arriveBy: return String(localized: "Arrive by")
        }
    }

    /// Whether the mode needs a date-time picker at all.
    public var usesExplicitTime: Bool { self != .leaveNow }
}

/// Which endpoint field the place picker is currently editing.
enum PlannerField: String, Identifiable, Hashable {
    case origin
    case destination

    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .origin: return String(localized: "Choose a starting point")
        case .destination: return String(localized: "Choose a destination")
        }
    }
}

// MARK: - Clock

enum PlanClock {
    /// "Now", expressed in the same day frame the journey's times live in.
    ///
    /// Journey times are seconds from midnight of the journey's `baseDate` and
    /// may exceed 86400. A countdown computed against today's midnight would be
    /// a day out for a journey that the router anchored on yesterday's service
    /// day — the 00:20 last bus case — so the offset has to be folded in.
    static func seconds(at date: Date, in timeZone: TimeZone, frame baseDate: ServiceDate) -> ServiceSeconds {
        let instant = ServiceInstant(date: date, in: timeZone)
        let dayOffset = instant.date.days(since: baseDate)
        return ServiceSeconds(clamping: Int(instant.seconds) + dayOffset * 86_400)
    }

    /// Wall-clock rendering of a journey time in the feed's zone.
    static func clockText(_ seconds: ServiceSeconds, baseDate: ServiceDate, in timeZone: TimeZone) -> String {
        Format.clock(ServiceInstant(date: baseDate, seconds: seconds).normalised, in: timeZone)
    }
}

// MARK: - Options

/// The subset of `PlanOptions` the rider can actually see, in a form that is
/// cheap to persist and cheap to compare. Kept separate from `PlanOptions` so
/// that a change to an engine default does not silently rewrite someone's saved
/// preferences.
struct PlannerOptionsState: Equatable {
    var maximumTransfers: Int = 4
    var maximumWalkMeters: Double = 1000
    var requiresWheelchairAccess: Bool = false
    /// Raw `TransitMode` values the rider has *enabled*. Empty means "everything",
    /// which is also the state a fresh install starts in.
    var enabledModeRawValues: Set<UInt8> = []

    static let selectableModes: [TransitMode] = [
        .rail, .subway, .tram, .ferry, .bus, .trolleybus, .monorail, .cableTram,
        .aerialLift, .funicular,
    ]

    var allowedModes: Set<TransitMode>? {
        guard !enabledModeRawValues.isEmpty else { return nil }
        var modes = Set(enabledModeRawValues.compactMap(TransitMode.init(rawValue:)))
        // A feed can classify a route as something this list does not name. Those
        // should not vanish because the rider unticked "ferry", so unclassified
        // service is always allowed through.
        modes.insert(.other)
        return modes
    }

    func isEnabled(_ mode: TransitMode) -> Bool {
        enabledModeRawValues.isEmpty || enabledModeRawValues.contains(mode.rawValue)
    }

    /// Toggling the first mode off has to materialise the full set first,
    /// otherwise "everything except the bus" would read as "only the bus".
    mutating func setEnabled(_ isEnabled: Bool, for mode: TransitMode) {
        var set = enabledModeRawValues.isEmpty
            ? Set(PlannerOptionsState.selectableModes.map(\.rawValue))
            : enabledModeRawValues
        if isEnabled {
            set.insert(mode.rawValue)
        } else {
            set.remove(mode.rawValue)
        }
        // Every mode ticked is the same thing as no filter, and storing it that
        // way keeps a later feed with new modes working.
        if set == Set(PlannerOptionsState.selectableModes.map(\.rawValue)) {
            enabledModeRawValues = []
        } else {
            enabledModeRawValues = set
        }
    }

    var modesStorageValue: String {
        enabledModeRawValues.sorted().map(String.init).joined(separator: ",")
    }

    static func modes(fromStorage value: String) -> Set<UInt8> {
        Set(value.split(separator: ",").compactMap { UInt8($0) })
    }

    /// Folds the rider's choices into a full `PlanOptions`, leaving every field
    /// the UI does not expose at the engine's default.
    func apply(to options: inout PlanOptions) {
        options.maximumTransfers = maximumTransfers
        options.maximumAccessWalkMeters = maximumWalkMeters
        options.maximumEgressWalkMeters = maximumWalkMeters
        // Total walk is what stops a "walk 3 km, ride 2 stops" answer; keep it
        // proportional to the per-leg limit rather than pinned to a constant.
        options.maximumTotalWalkMeters = max(maximumWalkMeters * 3, maximumWalkMeters)
        options.requiresWheelchairAccess = requiresWheelchairAccess
        options.allowedModes = allowedModes
    }

    var summary: String {
        var parts: [String] = [
            String(localized: "Up to \(maximumTransfers) transfers"),
            Format.distance(meters: maximumWalkMeters),
        ]
        if requiresWheelchairAccess {
            parts.append(String(localized: "Step-free"))
        }
        if !enabledModeRawValues.isEmpty {
            parts.append(String(localized: "\(enabledModeRawValues.count) modes"))
        }
        return parts.joined(separator: " · ")
    }
}

extension TransitMode {
    /// Human name for the options sheet. `localizedNameKey` needs a strings table
    /// that does not exist yet, and an untranslated "mode.bus" on screen is worse
    /// than a literal Xcode can extract.
    var plannerDisplayName: String {
        switch self {
        case .tram: return String(localized: "Tram")
        case .subway: return String(localized: "Subway")
        case .rail: return String(localized: "Train")
        case .bus: return String(localized: "Bus")
        case .ferry: return String(localized: "Ferry")
        case .cableTram: return String(localized: "Cable car")
        case .aerialLift: return String(localized: "Aerial lift")
        case .funicular: return String(localized: "Funicular")
        case .trolleybus: return String(localized: "Trolleybus")
        case .monorail: return String(localized: "Monorail")
        case .taxi: return String(localized: "Taxi")
        case .other: return String(localized: "Other")
        }
    }
}

// MARK: - Empty states

/// Why a search produced nothing, and what the rider can do about it.
enum PlannerEmptyReason: Equatable {
    case notEnoughInput
    case noFeed
    case needsLocation
    case noResults
    case noStopsNearOrigin
    case noStopsNearDestination
    case dateNotCovered(ServiceDate)
    case sameEndpoints

    var systemImage: String {
        switch self {
        case .notEnoughInput: return "arrow.triangle.swap"
        case .noFeed: return "arrow.down.circle"
        case .needsLocation: return "location.slash"
        case .noResults: return "clock.badge.questionmark"
        case .noStopsNearOrigin, .noStopsNearDestination: return "mappin.slash"
        case .dateNotCovered: return "calendar.badge.exclamationmark"
        case .sameEndpoints: return "figure.walk"
        }
    }

    var title: String {
        switch self {
        case .notEnoughInput: return String(localized: "Where to?")
        case .noFeed: return String(localized: "No timetable yet")
        case .needsLocation: return String(localized: "Location unavailable")
        case .noResults: return String(localized: "No journeys found")
        case .noStopsNearOrigin: return String(localized: "Nothing runs near the start")
        case .noStopsNearDestination: return String(localized: "Nothing runs near the destination")
        case .dateNotCovered: return String(localized: "Outside the timetable")
        case .sameEndpoints: return String(localized: "You are already there")
        }
    }

    var message: String {
        switch self {
        case .notEnoughInput:
            return String(localized: "Pick a starting point and a destination to see journeys.")
        case .noFeed:
            return String(localized: "Install a transit feed for your city and the planner will work offline.")
        case .needsLocation:
            return String(localized: "Allow location access, or set a starting point by hand.")
        case .noResults:
            return String(localized: "No service connects these places at this time. Try a later departure, more transfers, or a longer walk.")
        case .noStopsNearOrigin:
            return String(localized: "There are no stops within walking distance of the starting point. Move the pin closer to a road with service, or allow a longer walk.")
        case .noStopsNearDestination:
            return String(localized: "There are no stops within walking distance of the destination. Move the pin closer to a road with service, or allow a longer walk.")
        case .dateNotCovered(let date):
            return String(localized: "The installed timetable does not cover \(date.gtfsString). Refreshing the feed usually fixes this.")
        case .sameEndpoints:
            return String(localized: "The start and the destination are the same place.")
        }
    }

    var actionTitle: String? {
        switch self {
        case .notEnoughInput: return String(localized: "Set destination")
        case .noFeed: return nil
        case .needsLocation: return String(localized: "Set starting point")
        case .noResults: return String(localized: "Adjust options")
        case .noStopsNearOrigin: return String(localized: "Change starting point")
        case .noStopsNearDestination: return String(localized: "Change destination")
        case .dateNotCovered: return String(localized: "Refresh timetable")
        case .sameEndpoints: return String(localized: "Change destination")
        }
    }

    init(planError: PlanError) {
        switch planError {
        case .noStopsNearOrigin: self = .noStopsNearOrigin
        case .noStopsNearDestination: self = .noStopsNearDestination
        case .dateNotCovered(let date): self = .dateNotCovered(date)
        case .trivialJourney: self = .sameEndpoints
        case .cancelled: self = .noResults
        }
    }
}

// MARK: - Preview fixtures

#if DEBUG
/// Hand-built `ViewData` for previews.
///
/// Deliberately literal: a preview that opens a real graph cannot run on a Mac
/// without a compiled feed, which would make the whole UI un-iterable.
enum PlannerPreviewData {
    static let baseDate = ServiceDate(year: 2026, month: 8, day: 9)

    static let busBadge = LineBadgeData(
        text: "42",
        backgroundHex: 0x2E7D32,
        foregroundHex: 0xFFFFFF,
        mode: .bus,
        accessibilityLabel: String(localized: "Bus 42")
    )

    static let railBadge = LineBadgeData(
        text: "M1",
        backgroundHex: 0x6A1B9A,
        foregroundHex: 0xFFFFFF,
        mode: .rail,
        accessibilityLabel: String(localized: "Train M1")
    )

    static let walkToStop = JourneyLegItem(
        id: "leg-walk-1",
        kind: .walk,
        badge: nil,
        headsign: "",
        fromName: String(localized: "My location"),
        toName: "Rothschild / Allenby",
        fromStop: nil,
        toStop: 100,
        departureSeconds: 51_900,
        arrivalSeconds: 52_140,
        status: .scheduled,
        distanceMeters: 280,
        intermediateStopCount: 0,
        intermediateStopNames: []
    )

    static let busRide = JourneyLegItem(
        id: "leg-ride-1",
        kind: .ride,
        badge: busBadge,
        headsign: "Central Station",
        fromName: "Rothschild / Allenby",
        toName: "Arlozorov / Ibn Gabirol",
        fromStop: 100,
        toStop: 140,
        departureSeconds: 52_320,
        arrivalSeconds: 53_400,
        status: .late(seconds: 120),
        distanceMeters: 0,
        intermediateStopCount: 5,
        intermediateStopNames: [
            "Allenby / Yehuda Halevy",
            "Herzl / Levinsky",
            "Central Bus Station",
            "Salame / Ha'Aliya",
            "Arlozorov / Dizengoff",
        ]
    )

    static let railRide = JourneyLegItem(
        id: "leg-ride-2",
        kind: .ride,
        badge: railBadge,
        headsign: "Haifa Center",
        fromName: "Arlozorov / Ibn Gabirol",
        toName: "University",
        fromStop: 140,
        toStop: 210,
        departureSeconds: 53_700,
        arrivalSeconds: 54_720,
        status: .onTime,
        distanceMeters: 0,
        intermediateStopCount: 2,
        intermediateStopNames: ["Bnei Brak", "Petah Tikva"]
    )

    static let walkToDestination = JourneyLegItem(
        id: "leg-walk-2",
        kind: .walk,
        badge: nil,
        headsign: "",
        fromName: "University",
        toName: "Engineering Faculty",
        fromStop: 210,
        toStop: nil,
        departureSeconds: 54_720,
        arrivalSeconds: 54_960,
        status: .scheduled,
        distanceMeters: 240,
        intermediateStopCount: 0,
        intermediateStopNames: []
    )

    /// `JourneyItem` keeps the engine value for re-selection, so a fixture needs
    /// one too. Building a `Journey` literal touches no graph.
    static let journeyValue = Journey(
        legs: [
            .walk(
                WalkLeg(
                    origin: LegPoint(
                        stop: nil,
                        coordinate: GeoPoint(latitude: 32.0645, longitude: 34.7745),
                        name: String(localized: "My location")
                    ),
                    destination: LegPoint(
                        stop: 100,
                        coordinate: GeoPoint(latitude: 32.0662, longitude: 34.7712),
                        name: "Rothschild / Allenby"
                    ),
                    departure: 51_900,
                    arrival: 52_140,
                    distanceMeters: 280
                )
            ),
            .ride(
                RideLeg(
                    pattern: 7, tripOffset: 3, trip: 4_211, route: 88,
                    boardPosition: 4, alightPosition: 10,
                    boardStop: 100, alightStop: 140,
                    scheduledDeparture: 52_200, scheduledArrival: 53_280,
                    departureDelay: 120, arrivalDelay: 120,
                    serviceDate: baseDate
                )
            ),
            .ride(
                RideLeg(
                    pattern: 12, tripOffset: 1, trip: 9_002, route: 31,
                    boardPosition: 2, alightPosition: 5,
                    boardStop: 140, alightStop: 210,
                    scheduledDeparture: 53_700, scheduledArrival: 54_720,
                    departureDelay: nil, arrivalDelay: nil,
                    serviceDate: baseDate
                )
            ),
            .walk(
                WalkLeg(
                    origin: LegPoint(
                        stop: 210,
                        coordinate: GeoPoint(latitude: 32.1131, longitude: 34.8043),
                        name: "University"
                    ),
                    destination: LegPoint(
                        stop: nil,
                        coordinate: GeoPoint(latitude: 32.1148, longitude: 34.8061),
                        name: "Engineering Faculty"
                    ),
                    departure: 54_720,
                    arrival: 54_960,
                    distanceMeters: 240
                )
            ),
        ],
        baseDate: baseDate
    )

    static let journey = JourneyItem(
        id: "preview-journey-1",
        journey: journeyValue,
        legs: [walkToStop, busRide, railRide, walkToDestination],
        departureSeconds: 51_900,
        arrivalSeconds: 54_960,
        baseDate: baseDate,
        durationSeconds: 3_060,
        transferCount: 1,
        walkMeters: 520,
        badges: [busBadge, railBadge],
        isWalkOnly: false,
        hasRealtime: true
    )

    static let directJourney = JourneyItem(
        id: "preview-journey-2",
        journey: Journey(legs: [.ride(
            RideLeg(
                pattern: 7, tripOffset: 5, trip: 4_299, route: 88,
                boardPosition: 4, alightPosition: 14,
                boardStop: 100, alightStop: 210,
                scheduledDeparture: 53_100, scheduledArrival: 55_020,
                departureDelay: nil, arrivalDelay: nil,
                serviceDate: baseDate
            )
        )], baseDate: baseDate),
        legs: [
            JourneyLegItem(
                id: "leg-ride-3",
                kind: .ride,
                badge: busBadge,
                headsign: "University",
                fromName: "Rothschild / Allenby",
                toName: "University",
                fromStop: 100,
                toStop: 210,
                departureSeconds: 53_100,
                arrivalSeconds: 55_020,
                status: .scheduled,
                distanceMeters: 0,
                intermediateStopCount: 9,
                intermediateStopNames: []
            ),
        ],
        departureSeconds: 53_100,
        arrivalSeconds: 55_020,
        baseDate: baseDate,
        durationSeconds: 1_920,
        transferCount: 0,
        walkMeters: 0,
        badges: [busBadge],
        isWalkOnly: false,
        hasRealtime: false
    )

    static let journeys: [JourneyItem] = [journey, directJourney]

    /// 14:25 on the fixture's service day, so previewed countdowns are sensible.
    static var previewNow: ServiceSeconds { 51_900 - 300 }
}
#endif
