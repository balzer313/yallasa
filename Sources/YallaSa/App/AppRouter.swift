import Foundation
import Combine
import YallaSaKit

public enum AppTab: String, Hashable, CaseIterable {
    case nearby, plan, lines, map, settings
}

/// Everything the app can push. Values, not views — so a deep link, a map
/// callout and a departure row all navigate through exactly one code path.
public enum AppDestination: Hashable {
    case stop(StopIndex)
    case pattern(PatternIndex, position: Int)
    case route(RouteIndex)
    case journey(JourneyItem)
    case feedPicker
}

/// One navigation path per tab, owned centrally.
///
/// Each tab keeps its own stack because that is what riders expect from a tab
/// bar: switching to Plan and back must not throw away the stop you were reading.
@MainActor
public final class AppRouter: ObservableObject {
    @Published public var nearbyPath: [AppDestination] = []
    @Published public var planPath: [AppDestination] = []
    @Published public var linesPath: [AppDestination] = []
    @Published public var mapPath: [AppDestination] = []
    /// Not in the original contract, but `AppTab` has five cases and `show(_:in:)`
    /// must not silently do nothing for the fifth. Settings owns feed management,
    /// which is a real navigation target from the Nearby empty state.
    @Published public var settingsPath: [AppDestination] = []
    @Published public var selectedTab: AppTab = .nearby

    public init() {}

    public func show(_ destination: AppDestination, in tab: AppTab) {
        selectedTab = tab
        switch tab {
        case .nearby: nearbyPath.append(destination)
        case .plan: planPath.append(destination)
        case .lines: linesPath.append(destination)
        case .map: mapPath.append(destination)
        case .settings: settingsPath.append(destination)
        }
    }

    /// Pops a tab back to its root. Used by the tab bar's re-tap gesture and after
    /// a feed swap, where every pushed index has just become meaningless.
    public func popToRoot(_ tab: AppTab) {
        switch tab {
        case .nearby: nearbyPath.removeAll()
        case .plan: planPath.removeAll()
        case .lines: linesPath.removeAll()
        case .map: mapPath.removeAll()
        case .settings: settingsPath.removeAll()
        }
    }

    /// A feed rebuild renumbers every stop, pattern and route, so any pushed
    /// destination now points at a different place in the network. Dropping the
    /// stacks is the only honest response.
    public func popAllToRoot() {
        for tab in AppTab.allCases { popToRoot(tab) }
    }
}
