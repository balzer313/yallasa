import Foundation
import MoveItKit

/// Hand-written view data for SwiftUI previews.
///
/// Deliberately *not* built from a real graph. A preview that needs a compiled
/// feed is a preview that never runs, and the whole reason `ViewData` is plain
/// data is so the UI can be worked on with nothing but literals. Shared across
/// features so every screen previews against the same recognisable fixture.
enum PreviewData {

    // MARK: - Dates

    static let date = ServiceDate(year: 2026, month: 8, day: 9)

    /// 08:00:00 — the reference "now" every preview counts down from.
    static let now: ServiceSeconds = 8 * 3600

    // MARK: - Badges

    static let bus42 = LineBadgeData(
        text: "42",
        backgroundHex: 0x2E7D32,
        foregroundHex: 0xFFFFFF,
        mode: .bus,
        accessibilityLabel: "Bus 42"
    )

    static let bus189 = LineBadgeData(
        text: "189",
        backgroundHex: 0x00695C,
        foregroundHex: 0xFFFFFF,
        mode: .bus,
        accessibilityLabel: "Bus 189"
    )

    static let redLine = LineBadgeData(
        text: "Red Line",
        backgroundHex: 0xC62828,
        foregroundHex: 0xFFFFFF,
        mode: .tram,
        accessibilityLabel: "Tram Red Line"
    )

    static let rail = LineBadgeData(
        text: "IC 71",
        backgroundHex: 0x6A1B9A,
        foregroundHex: 0xFFFFFF,
        mode: .rail,
        accessibilityLabel: "Train IC 71"
    )

    static let ferry = LineBadgeData(
        text: "F1",
        backgroundHex: 0x0277BD,
        foregroundHex: 0xFFFFFF,
        mode: .ferry,
        accessibilityLabel: "Ferry F1"
    )

    // MARK: - Departures

    static func departure(
        id: String,
        badge: LineBadgeData,
        headsign: String,
        stopName: String = "Rothschild / Allenby",
        stopCode: String = "24518",
        stop: StopIndex = 1,
        inSeconds: Int32,
        status: LiveStatus = .scheduled,
        walkMeters: Double? = 180
    ) -> DepartureItem {
        DepartureItem(
            id: id,
            badge: badge,
            headsign: headsign,
            stop: stop,
            stopName: stopName,
            stopCode: stopCode,
            pattern: 7,
            trip: 91,
            position: 4,
            departureSeconds: now + inSeconds,
            scheduledSeconds: now + inSeconds,
            queryDate: date,
            status: status,
            walkMeters: walkMeters
        )
    }

    static let departures: [DepartureItem] = [
        departure(id: "d1", badge: bus42, headsign: "Central Station", inSeconds: 40, status: .onTime),
        departure(id: "d2", badge: redLine, headsign: "Harbour", inSeconds: 260, status: .late(seconds: 210)),
        departure(id: "d3", badge: bus189, headsign: "University — North Campus via the Old Quarter", inSeconds: 720),
        departure(id: "d4", badge: rail, headsign: "Airport", inSeconds: 1_980, status: .early(seconds: 90)),
        departure(id: "d5", badge: ferry, headsign: "Island Pier", inSeconds: 3_600, status: .cancelled)
    ]

    // MARK: - Stops

    static let stop = StopItem(
        id: 1,
        stop: 1,
        name: "Rothschild / Allenby",
        code: "24518",
        coordinate: GeoPoint(latitude: 32.0644, longitude: 34.7745),
        distanceMeters: 180,
        lines: [bus42, bus189, redLine, rail],
        accessibility: .accessible
    )

    static let farStop = StopItem(
        id: 2,
        stop: 2,
        name: "Carmel Market",
        code: "24610",
        coordinate: GeoPoint(latitude: 32.0688, longitude: 34.7690),
        distanceMeters: 460,
        lines: [bus189, ferry],
        accessibility: .unknown
    )

    // MARK: - Journeys

    private static let walkLeg = WalkLeg(
        origin: LegPoint(stop: nil, coordinate: GeoPoint(latitude: 32.063, longitude: 34.773), name: "Your location"),
        destination: LegPoint(stop: 1, coordinate: GeoPoint(latitude: 32.0644, longitude: 34.7745), name: "Rothschild / Allenby"),
        departure: now,
        arrival: now + 240,
        distanceMeters: 190
    )

    private static let rideLeg = RideLeg(
        pattern: 7,
        tripOffset: 3,
        trip: 91,
        route: 12,
        boardPosition: 4,
        alightPosition: 11,
        boardStop: 1,
        alightStop: 2,
        scheduledDeparture: now + 300,
        scheduledArrival: now + 1_140,
        departureDelay: 180,
        arrivalDelay: 150,
        serviceDate: date
    )

    static let journey = Journey(legs: [.walk(walkLeg), .ride(rideLeg)], baseDate: date)

    static let journeyItem = JourneyItem(
        id: journey.id,
        journey: journey,
        legs: [
            JourneyLegItem(
                id: "\(journey.id)#0",
                kind: .walk,
                badge: nil,
                headsign: "",
                fromName: "Your location",
                toName: "Rothschild / Allenby",
                fromStop: nil,
                toStop: 1,
                departureSeconds: now,
                arrivalSeconds: now + 240,
                status: .scheduled,
                distanceMeters: 190,
                intermediateStopCount: 0,
                intermediateStopNames: []
            ),
            JourneyLegItem(
                id: "\(journey.id)#1",
                kind: .ride,
                badge: bus42,
                headsign: "Central Station",
                fromName: "Rothschild / Allenby",
                toName: "Carmel Market",
                fromStop: 1,
                toStop: 2,
                departureSeconds: now + 480,
                arrivalSeconds: now + 1_290,
                status: .late(seconds: 180),
                distanceMeters: 0,
                intermediateStopCount: 6,
                intermediateStopNames: [
                    "Allenby / Yehuda Halevi",
                    "Herzl / Nahalat Binyamin",
                    "Magen David Square",
                    "King George / Bezalel",
                    "Dizengoff Square",
                    "Arlozorov / Ibn Gvirol"
                ]
            )
        ],
        departureSeconds: now,
        arrivalSeconds: now + 1_290,
        baseDate: date,
        durationSeconds: 1_290,
        transferCount: 0,
        walkMeters: 190,
        badges: [bus42],
        isWalkOnly: false,
        hasRealtime: true
    )

    // MARK: - Patterns

    static let pattern = PatternItem(
        id: 7,
        pattern: 7,
        route: 12,
        badge: bus42,
        headsign: "Central Station",
        stopCount: 28,
        direction: 0
    )

    static let diagramStops = [
        "Rothschild / Allenby",
        "Allenby / Yehuda Halevi",
        "Herzl / Nahalat Binyamin",
        "Magen David Square",
        "King George / Bezalel",
        "Dizengoff Square",
        "Carmel Market"
    ]
}
