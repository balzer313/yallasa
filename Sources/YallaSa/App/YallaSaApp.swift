import SwiftUI
import YallaSaKit

@main
struct YallaSaApp: App {
    /// The engine facade. A singleton because it owns a memory-mapped graph, and
    /// two of those would double the app's footprint for no benefit.
    @StateObject private var service = TransitService.shared
    @StateObject private var router = AppRouter()
    @StateObject private var location = LocationProvider()
    @StateObject private var places = PlacesStore()
    @StateObject private var favorites = FavoriteLinesStore()
    @StateObject private var handoff = PlanHandoff()
    /// The trip currently being followed, and its שנ״צ alarms. App-level so a
    /// running trip survives switching tabs and reopening the journey screen.
    @StateObject private var tripTracker = TripTracker()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(service)
                .environmentObject(router)
                .environmentObject(location)
                .environmentObject(places)
                .environmentObject(favorites)
                .environmentObject(handoff)
                .environmentObject(tripTracker)
                .task { await service.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // Realtime polling is tied to the foreground. There is no
                    // server to keep in sync and no notification to deliver, so
                    // polling in the background would spend battery for nothing.
                    switch phase {
                    case .active:
                        location.start()
                    case .inactive, .background:
                        service.stopRealtimePolling()
                        location.stop()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
