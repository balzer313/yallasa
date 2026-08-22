import SwiftUI
import MapKit
import YallaSaKit

@MainActor
final class MapViewModel: ObservableObject {
    /// Hard ceiling on annotations. A metro feed has tens of thousands of stops
    /// and MapKit will happily try to lay out every one of them, which locks the
    /// device. Below the zoom threshold we show nothing but a hint; above it we
    /// cap and prioritise.
    static let maximumAnnotations = 250
    /// Roughly "a few streets across". Wider than this and individual stops are
    /// not useful anyway.
    static let visibleSpanLimitMeters: Double = 6_000

    @Published private(set) var stops: [StopItem] = []
    @Published private(set) var isZoomedOut = true
    @Published private(set) var truncated = false

    private let service: TransitService
    private let presenter: Presenter
    private var reloadTask: Task<Void, Never>?

    init(service: TransitService, presenter: Presenter) {
        self.service = service
        self.presenter = presenter
    }

    func regionChanged(centre: GeoPoint, spanMeters: Double) {
        isZoomedOut = spanMeters > MapViewModel.visibleSpanLimitMeters
        guard !isZoomedOut else {
            stops = []
            truncated = false
            return
        }

        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A small settle delay: panning fires this continuously and there is
            // no point rebuilding annotations for frames nobody sees.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let radius = max(spanMeters / 2, 150)
            let nearby = self.service.nearbyStops(
                to: centre,
                radiusMeters: radius,
                limit: MapViewModel.maximumAnnotations * 2
            )
            guard !Task.isCancelled else { return }

            let items = nearby.compactMap {
                self.presenter.stopItem($0.stop, distanceMeters: $0.distanceMeters)
            }
            // Prioritise interchanges: when the cap bites, the stops worth seeing
            // are the ones served by the most lines.
            let ranked = items.sorted { lhs, rhs in
                lhs.lines.count == rhs.lines.count
                    ? (lhs.distanceMeters ?? 0) < (rhs.distanceMeters ?? 0)
                    : lhs.lines.count > rhs.lines.count
            }
            self.truncated = ranked.count > MapViewModel.maximumAnnotations
            self.stops = Array(ranked.prefix(MapViewModel.maximumAnnotations))
        }
    }
}

/// The live map: stops, and buses actually moving.
///
/// No longer a screen of its own. It is the background of `HomeView`, so it
/// carries no navigation title and no toolbar — anything drawn over a map costs
/// a strip of the thing the screen exists to show. It keeps its own sheets for a
/// tapped bus or stop, which is precisely why the departures board above it
/// could not also be a `.sheet`.
struct MapCanvas: View {
    @StateObject private var viewModel: MapViewModel

    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var location: LocationProvider

    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: StopItem?
    @State private var selectedVehicle: LiveVehicle?
    /// The region the map is showing, kept so the polling task can ask for
    /// vehicles in exactly what is on screen rather than a guess.
    @State private var visibleBounds: GeoBounds?
    /// Drives the staleness fade. Vehicles do not move between polls but their
    /// *age* does, and a marker that never dims is the bug this avoids.
    @State private var tick = Date()

    private static let tickInterval: TimeInterval = 5

    init(service: TransitService = .shared, presenter: Presenter? = nil) {
        _viewModel = StateObject(
            wrappedValue: MapViewModel(
                service: service,
                presenter: presenter ?? Presenter(service: service)
            )
        )
    }

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()

            // Vehicles are added after stops so they draw on top: a moving bus
            // hidden behind a stop pin is the one thing the rider is looking for.
            ForEach(service.liveVehicles) { vehicle in
                Annotation(
                    vehicle.lineName,
                    coordinate: CLLocationCoordinate2D(
                        latitude: vehicle.position.point.latitude,
                        longitude: vehicle.position.point.longitude
                    )
                ) {
                    Button { selectedVehicle = vehicle } label: {
                        LiveVehicleMarker(vehicle: vehicle, now: tick)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(viewModel.stops) { stop in
                Annotation(
                    stop.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: stop.coordinate.latitude,
                        longitude: stop.coordinate.longitude
                    )
                ) {
                    Button {
                        selected = stop
                    } label: {
                        stopPin(stop)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(stop.name))
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            let centre = GeoPoint(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            )
            // Latitude degrees are constant in metres, which makes this a good
            // enough proxy for "how much am I looking at".
            let spanMeters = region.span.latitudeDelta * 110_540
            viewModel.regionChanged(centre: centre, spanMeters: spanMeters)

            visibleBounds = GeoBounds(
                minLatitude: region.center.latitude - region.span.latitudeDelta / 2,
                minLongitude: region.center.longitude - region.span.longitudeDelta / 2,
                maxLatitude: region.center.latitude + region.span.latitudeDelta / 2,
                maxLongitude: region.center.longitude + region.span.longitudeDelta / 2
            )
        }
        .overlay(alignment: .top) { banner }
        .overlay(alignment: .bottomLeading) { liveChip }
        .sheet(item: $selectedVehicle) { vehicle in
            LiveVehicleSheet(vehicle: vehicle, now: tick) {
                guard let route = vehicle.route else { return }
                selectedVehicle = nil
                router.show(.route(route), in: .map)
            }
            .presentationDetents([.height(280)])
        }
        .sheet(item: $selected) { stop in
            MapStopSheet(stop: stop) {
                selected = nil
                router.show(.stop(stop.stop), in: .map)
            }
            .presentationDetents([.height(240), .medium])
        }
        .task(id: service.activeFeed?.id) {
            guard service.supportsLiveVehicles else { return }
            service.startLiveVehiclePolling(bounds: { visibleBounds })
        }
        .task {
            // A timer rather than a per-marker one: 300 markers each animating
            // their own age is 300 view invalidations a second.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                tick = Date()
            }
        }
        .onDisappear {
            service.stopLiveVehiclePolling()
            service.clearLiveVehicles()
        }
        .task {
            if let here = location.coordinate ?? service.activeFeed?.metadata.bounds.centerIfValid {
                camera = .region(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
                        latitudinalMeters: 1500,
                        longitudinalMeters: 1500
                    )
                )
                // Seed the polling region from the same point.
                //
                // `visibleBounds` was only ever assigned by onMapCameraChange,
                // which fires when a camera movement *ends* — so until the rider
                // dragged the map it stayed nil, the poll loop skipped every
                // tick, and not one bus appeared. The map looked broken on the
                // one screen the feature exists for.
                if visibleBounds == nil {
                    visibleBounds = GeoBounds(
                        minLatitude: here.latitude - 0.02,
                        minLongitude: here.longitude - 0.02,
                        maxLatitude: here.latitude + 0.02,
                        maxLongitude: here.longitude + 0.02
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var liveChip: some View {
        if service.supportsLiveVehicles {
            LiveStatusChip(
                updatedAt: service.liveVehiclesUpdatedAt,
                vehicleCount: service.liveVehicles.count,
                failed: service.liveVehiclesFailed,
                now: tick
            )
            .padding(Theme.Spacing.medium)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if viewModel.isZoomedOut {
            Text("Zoom in to see stops")
                .font(Theme.Typography.caption)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, Theme.Spacing.small)
        } else if viewModel.truncated {
            Text("Showing the busiest \(MapViewModel.maximumAnnotations) stops here")
                .font(Theme.Typography.caption)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, Theme.Spacing.small)
        }
    }

    private func stopPin(_ stop: StopItem) -> some View {
        let mode = stop.lines.first?.mode ?? .bus
        return ZStack {
            Circle()
                .fill(Theme.Palette.surface)
                .frame(width: 28, height: 28)
                .shadow(radius: 1, y: 1)
            Circle()
                .strokeBorder(Theme.Palette.hex(stop.lines.first?.backgroundHex ?? mode.defaultColor), lineWidth: 2)
                .frame(width: 28, height: 28)
            ModeIcon(mode, size: 13)
        }
    }
}

/// The callout: enough to decide whether to walk to this stop, and one tap to
/// the full board if it is.
struct MapStopSheet: View {
    let stop: StopItem
    let openDetail: () -> Void

    @EnvironmentObject private var service: TransitService
    @Environment(\.presenter) private var presenter

    @State private var departures: [DepartureItem] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            StopRowView(item: stop)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if departures.isEmpty {
                Text("No more departures today.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let now = nowSeconds(at: timeline.date)
                    VStack(spacing: Theme.Spacing.small) {
                        ForEach(departures.prefix(3)) { departure in
                            DepartureRowView(item: departure, now: now, showsStop: false)
                        }
                    }
                }
            }

            Button(action: openDetail) {
                Text("All departures")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.regular)
        .task {
            let raw = await service.departures(atStop: stop.stop, limit: 6)
            departures = raw.compactMap { presenter?.departureItem($0, walkMeters: nil) }
            isLoading = false
        }
    }

    private func nowSeconds(at date: Date) -> ServiceSeconds {
        let instant = ServiceInstant(date: date, in: service.timeZone)
        guard let first = departures.first else { return instant.seconds }
        let dayDelta = instant.date.days(since: first.queryDate)
        return instant.seconds + ServiceSeconds(clamping: dayDelta) * 86_400
    }
}

private extension GeoBounds {
    /// The centre, or nil for the empty sentinel — a feed whose bounds never got
    /// extended would otherwise centre the map on infinity.
    var centerIfValid: GeoPoint? {
        isEmpty ? nil : center
    }
}
