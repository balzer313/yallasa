# App contracts

Normative for everything under `Sources/YallaSa/`. The engine contracts are in
`CONTRACTS.md`; this file covers the SwiftUI layer only.

## Architecture

```
SwiftUI views  ──reads──▶  ViewData structs  ◀──builds──  Presenter
      │                                                       │
      └──────────── actions ─────────▶ Feature view models ────┘
                                              │
                                       TransitService  (YallaSaKit)
```

**Views never touch `TransitGraph`.** A view that reaches into the graph to get a
stop name is a view that cannot be previewed, cannot be tested, and breaks the
moment a feed is swapped mid-render. Feature view models call `TransitService`,
convert results through `Presenter`, and publish plain `ViewData` structs.

- Views: `struct`, no business logic, no `async` work in `body`.
- View models: `@MainActor final class ... : ObservableObject`, one per screen.
- All engine work is already off-main inside `TransitService`; view models just
  `await` it.
- Every screen handles four states explicitly: loading, empty, error, content.
  A blank screen is a bug, not an empty state.

## Fixed, already written — do not modify

| Type | File |
|---|---|
| `Theme`, `LiveStatus` | `DesignSystem/Theme.swift` |
| `Format` | `DesignSystem/Formatters.swift` |
| `TransitService`, `TransitServiceState` | `YallaSaKit/TransitService.swift` |
| everything else in `YallaSaKit` | see `CONTRACTS.md` |

## 1. View data — `Presentation/ViewData.swift` *(owned by the shell agent)*

```swift
public struct LineBadgeData: Hashable, Sendable {
    public var text: String            // "42", "M14", "Red Line"
    public var backgroundHex: UInt32
    public var foregroundHex: UInt32
    public var mode: TransitMode
    public var accessibilityLabel: String   // "Bus 42"
}

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
}

public struct StopItem: Identifiable, Hashable, Sendable {
    public var id: StopIndex
    public var stop: StopIndex
    public var name: String
    public var code: String
    public var coordinate: GeoPoint
    public var distanceMeters: Double?
    public var lines: [LineBadgeData]   // deduped, capped at 8 by the presenter
    public var accessibility: AccessibilityFlag
}

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
}

public struct PatternItem: Identifiable, Hashable, Sendable {
    public var id: PatternIndex
    public var pattern: PatternIndex
    public var route: RouteIndex
    public var badge: LineBadgeData
    public var headsign: String
    public var stopCount: Int
    public var direction: UInt8
}
```

## 2. `Presentation/Presenter.swift` *(owned by the shell agent)*

```swift
/// Turns engine values into view data. Holds the graph so views never have to.
@MainActor
public final class Presenter {
    public init(service: TransitService)
    public var timeZone: TimeZone { get }
    public var isReady: Bool { get }

    public func badge(forRoute route: RouteIndex) -> LineBadgeData
    public func departureItem(_ departure: Departure, walkMeters: Double?) -> DepartureItem?
    public func stopItem(_ stop: StopIndex, distanceMeters: Double?) -> StopItem?
    public func journeyItem(_ journey: Journey) -> JourneyItem
    public func patternItem(_ pattern: PatternIndex) -> PatternItem?
    public func stopName(_ stop: StopIndex) -> String
    /// Names of the stops strictly between two positions on a pattern.
    public func intermediateStopNames(pattern: PatternIndex, from: Int, to: Int, limit: Int) -> [String]
}
```

Returns optionals where the graph may have gone away (feed swap) — callers drop
nils rather than crash.

## 3. Shared components *(owned by the shell agent)* — `DesignSystem/Components/`

Pinned signatures. Other agents build against exactly these.

```swift
public struct LineBadge: View {
    public init(_ data: LineBadgeData, size: LineBadge.Size = .regular)
    public enum Size { case small, regular, large }
}

public struct ModeIcon: View {
    public init(_ mode: TransitMode, size: CGFloat = 16)
}

/// The big "3 min" with its live/scheduled treatment.
public struct CountdownLabel: View {
    public init(seconds: Int32, status: LiveStatus, showsClock: Bool = false,
                clockText: String? = nil)
}

public struct DepartureRowView: View {
    public init(item: DepartureItem, now: ServiceSeconds, showsStop: Bool = true)
}

public struct StopRowView: View {
    public init(item: StopItem)
}

public struct JourneyCardView: View {
    public init(item: JourneyItem, now: ServiceSeconds, timeZone: TimeZone)
}

public struct SectionCard<Content: View>: View {
    public init(title: String?, systemImage: String? = nil, @ViewBuilder content: () -> Content)
}

public struct EmptyStateView: View {
    public init(systemImage: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil)
}

public struct ErrorStateView: View {
    public init(message: String, retryTitle: String = "Try again", retry: (() -> Void)? = nil)
}

public struct LoadingStateView: View {
    public init(message: String)
}

/// Vertical route diagram used in journey detail and pattern detail.
public struct LineDiagram: View {
    public init(color: Color, stops: [String], highlightFirst: Bool = true, highlightLast: Bool = true)
}
```

Accessibility requirements for all of them: every row is one VoiceOver element
with a composed label (line, destination, stop, countdown), `LineBadge` carries
its `accessibilityLabel` and the raw colour is never the only signal, countdowns
use `Format.countdownAccessible`, and everything respects Dynamic Type up to
AX5 (no fixed-height rows containing scaled text).

## 4. Navigation *(owned by the shell agent)*

```swift
public enum AppDestination: Hashable {
    case stop(StopIndex)
    case pattern(PatternIndex, position: Int)
    case route(RouteIndex)
    case journey(JourneyItem)
    case feedPicker
}

@MainActor
public final class AppRouter: ObservableObject {
    @Published public var nearbyPath: [AppDestination]
    @Published public var planPath: [AppDestination]
    @Published public var linesPath: [AppDestination]
    @Published public var mapPath: [AppDestination]
    @Published public var selectedTab: AppTab
    public func show(_ destination: AppDestination, in tab: AppTab)
}

public enum AppTab: String, Hashable, CaseIterable { case nearby, plan, lines, map, settings }
```

Each tab owns a `NavigationStack(path:)`. `StopDetailView` and
`PatternDetailView` are shared destinations, owned by the explore agent, and
must be reachable from every stack.

## 5. Location *(owned by the shell agent)* — `Services/LocationProvider.swift`

```swift
@MainActor
public final class LocationProvider: NSObject, ObservableObject {
    @Published public private(set) var coordinate: GeoPoint?
    @Published public private(set) var authorization: CLAuthorizationStatus
    @Published public private(set) var isLocating: Bool
    public func requestPermission()
    public func start()
    public func stop()
    /// Last known location, or the active feed's centre when permission is denied
    /// — the app must remain useful without location.
    public func bestGuessCoordinate(fallback: GeoPoint?) -> GeoPoint?
}
```

Uses `kCLLocationAccuracyNearestTenMeters` and a 20 m distance filter. Stops
updating when no screen needs it.

## 6. Persistence *(owned by the explore agent)* — `Services/`

```swift
public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case home, work, favorite, recent }
    public var id: String
    public var kind: Kind
    public var name: String
    public var coordinate: GeoPoint
    public var stop: StopIndex?      // resolved lazily; may be stale after a feed swap
    public var stopIdentifier: String?   // the GTFS id, which survives a feed swap
    public var addedAt: Date
}

@MainActor public final class PlacesStore: ObservableObject {
    @Published public private(set) var places: [SavedPlace]
    public func add(_ place: SavedPlace); public func remove(id: String)
    public func home: SavedPlace?; public func work: SavedPlace?
    public func recordRecent(_ place: SavedPlace)   // caps at 20, dedupes
}

@MainActor public final class FavoriteLinesStore: ObservableObject {
    @Published public private(set) var routeIdentifiers: Set<String>
    @Published public private(set) var stopIdentifiers: Set<String>
    public func toggleRoute(_ gtfsID: String); public func toggleStop(_ gtfsID: String)
}
```

Both persist to JSON in Application Support. **Store GTFS string ids, not
indices** — indices are meaningless after a feed rebuild, and a favourite that
silently points at a different bus stop after an update is worse than no
favourite at all.

## 7. Screens and ownership

| Folder | Owner | Screens |
|---|---|---|
| `App/`, `DesignSystem/Components/`, `Presentation/`, `Features/Nearby/`, `Services/LocationProvider.swift` | shell agent | app entry, tab shell, onboarding/feed gate, Nearby departures |
| `Features/Planner/`, `Features/Journey/` | planner agent | from/to planner, place search, results list, journey detail |
| `Features/Lines/`, `Features/Map/`, `Features/Settings/`, `Features/StopDetail/`, `Services/PlacesStore.swift`, `Services/FavoriteLinesStore.swift` | explore agent | line browser, pattern/timetable detail, stop detail, map, settings, feed management |

## 8. Non-negotiables

- iOS 17 minimum. SwiftUI, MapKit, CoreLocation only. No third-party packages.
- No `!` force unwraps in view code. No `fatalError` outside `preconditionFailure`
  for genuine programmer error.
- Every `Text` that shows user-facing copy uses `String(localized:)` or a literal
  that Xcode can extract. No string concatenation for sentences.
- Timer-driven countdowns use one shared `TimelineView(.periodic)` per screen,
  never a `Timer` per row.
- Previews for every screen, driven by a fixture presenter, so the UI can be
  worked on without a compiled feed.
