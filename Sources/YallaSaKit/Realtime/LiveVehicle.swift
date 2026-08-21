import Foundation

/// A live vehicle position joined to the line it is running, ready to draw.
///
/// `VehiclePosition` on its own carries a `lineReference` — a bare GTFS
/// `route_id` like `"7433"`, which is meaningless to a rider. This pairs it with
/// what the compiled graph knows about that route: the number on the front of
/// the bus, its mode, and its colour. The join is the whole point, and it is
/// only possible because Israel's SIRI `LineRef` *is* the GTFS `route_id`.
public struct LiveVehicle: Identifiable, Hashable, Sendable {
    public var position: VehiclePosition
    /// The route in the active graph, when the line is one we have compiled.
    /// Absent for a bus running a line outside the installed region — common
    /// near the edge of a metro clip, and a good reason to keep drawing it.
    public var route: RouteIndex?
    /// "393", "480" — what is written on the vehicle.
    public var lineName: String
    public var mode: TransitMode
    /// Packed RGB, matching `TransitGraph.routeColor(_:)`.
    public var color: UInt32
    /// The feed's own foreground for that colour. Preferred over computing a
    /// contrast locally: agencies pick these deliberately and a badge that
    /// disagrees with every printed timetable looks wrong even when it is
    /// technically more readable.
    public var textColor: UInt32

    public var id: String { position.id }

    public init(
        position: VehiclePosition,
        route: RouteIndex?,
        lineName: String,
        mode: TransitMode,
        color: UInt32,
        textColor: UInt32
    ) {
        self.position = position
        self.route = route
        self.lineName = lineName
        self.mode = mode
        self.color = color
        self.textColor = textColor
    }
}

extension TransitGraph {
    /// Maps GTFS `route_id` to its index, built once and reused.
    ///
    /// A live refresh resolves a few hundred vehicles every twenty seconds; a
    /// linear scan of `routeCount` for each one would be a few hundred thousand
    /// string comparisons a minute, on the main actor, for a redraw.
    public func routeIdentifierIndex() -> [String: RouteIndex] {
        var map: [String: RouteIndex] = [:]
        map.reserveCapacity(routeCount)
        for raw in 0..<routeCount {
            let route = RouteIndex(raw)
            map[routeIdentifier(route)] = route
        }
        return map
    }

    /// Joins a raw position to the graph. Falls back to the bare line reference
    /// when the route is not in this feed, because a bus drawn with an unhelpful
    /// label still tells you a bus is there.
    public func resolve(_ position: VehiclePosition, using index: [String: RouteIndex]) -> LiveVehicle {
        guard let route = index[position.lineReference] else {
            return LiveVehicle(
                position: position,
                route: nil,
                lineName: position.lineReference,
                mode: .bus,
                color: TransitMode.bus.defaultColor,
                textColor: 0xFFFFFF
            )
        }
        let short = routeShortName(route)
        return LiveVehicle(
            position: position,
            route: route,
            lineName: short.isEmpty ? position.lineReference : short,
            mode: routeMode(route),
            color: routeColor(route),
            textColor: routeTextColor(route)
        )
    }
}
