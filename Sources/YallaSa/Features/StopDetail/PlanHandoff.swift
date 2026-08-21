import Foundation
import Combine
import YallaSaKit

/// Carries a "plan a trip from/to here" request across a tab switch.
///
/// `AppDestination` can express *navigate to a stop* but not *pre-fill the
/// planner with this stop*, and pushing `.stop` onto the planner's stack would
/// simply open stop detail again inside the wrong tab. Until the navigation
/// contract grows a case for it, the explore screens set a request here and
/// switch tabs with `AppRouter`; the planner reads it on appear and clears it.
///
/// Degrades honestly: if nothing consumes the request, the rider still lands on
/// the planner — with an empty form rather than a wrong one.
@MainActor
public final class PlanHandoff: ObservableObject {
    public struct Request: Hashable, Sendable {
        public enum Role: Hashable, Sendable { case origin, destination }

        public var role: Role
        /// Index into the *current* graph. Re-derive from `stopIdentifier` if a
        /// feed swap could have happened in between.
        public var stop: StopIndex?
        public var stopIdentifier: String?
        public var coordinate: GeoPoint
        public var name: String

        public init(
            role: Role,
            stop: StopIndex?,
            stopIdentifier: String?,
            coordinate: GeoPoint,
            name: String
        ) {
            self.role = role
            self.stop = stop
            self.stopIdentifier = stopIdentifier
            self.coordinate = coordinate
            self.name = name
        }

        /// Ready to hand straight to `PlanRequest`.
        public var endpoint: PlanEndpoint {
            if let stop, stop >= 0 { return .stop(stop) }
            return .coordinate(coordinate)
        }

        public var savedPlace: SavedPlace {
            SavedPlace(
                kind: .recent,
                name: name,
                coordinate: coordinate,
                stop: stop,
                stopIdentifier: stopIdentifier
            )
        }
    }

    public static let shared = PlanHandoff()

    @Published public private(set) var pending: Request?

    public init() {}

    public func request(_ request: Request) {
        pending = request
    }

    /// Reads and clears in one step, so a request is never acted on twice.
    public func take() -> Request? {
        defer { pending = nil }
        return pending
    }

    public func clear() {
        pending = nil
    }
}
