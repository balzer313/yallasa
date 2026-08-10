import Foundation
import Combine
import CoreLocation
import MoveItKit

/// The rider's position, and nothing else.
///
/// Two behaviours matter more than the plumbing. First, the app must stay useful
/// with location switched off — every caller goes through
/// `bestGuessCoordinate(fallback:)`, which falls back to the installed feed's
/// centre, so a denied permission downgrades the experience instead of ending it.
/// Second, updates stop the moment no screen needs them: a transit app that holds
/// the location hardware open in the background is a transit app people delete
/// after one look at the battery screen.
@MainActor
public final class LocationProvider: NSObject, ObservableObject {
    @Published public private(set) var coordinate: GeoPoint?
    @Published public private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var isLocating: Bool = false

    private let manager = CLLocationManager()

    /// Whether a screen has asked for updates. Kept separately from `isLocating`
    /// so that a permission granted *after* `start()` resumes automatically.
    private var wantsUpdates = false

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // 20 m is roughly one bus stop's worth of movement. Anything finer just
        // wakes the app up to redraw the same board.
        manager.distanceFilter = 20
        authorization = manager.authorizationStatus
    }

    // MARK: - Control

    public func requestPermission() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    public func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .notDetermined:
            // The prompt is the request; updates begin from the authorization
            // callback once the rider answers.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            isLocating = false
        @unknown default:
            isLocating = false
        }
    }

    public func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        isLocating = false
    }

    /// Last known location, or the active feed's centre when permission is denied
    /// — the app must remain useful without location.
    public func bestGuessCoordinate(fallback: GeoPoint?) -> GeoPoint? {
        if let coordinate, coordinate.isValid { return coordinate }
        guard let fallback, fallback.isValid else { return nil }
        return fallback
    }

    /// True when the rider has actively said no. Distinct from "not asked yet",
    /// which deserves a prompt rather than an error state.
    public var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    public var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    // MARK: - Private

    private func beginUpdates() {
        guard wantsUpdates else { return }
        isLocating = true
        manager.startUpdatingLocation()
    }

    fileprivate func apply(_ point: GeoPoint) {
        guard point.isValid else { return }
        coordinate = point
        // A fix has arrived; the spinner has done its job even though updates
        // continue in the background.
        isLocating = false
    }

    fileprivate func applyAuthorization(_ status: CLAuthorizationStatus) {
        authorization = status
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            isLocating = false
            // Deliberately keep the last known coordinate: a rider who revokes
            // permission mid-session is better served by a slightly stale board
            // than by an empty one.
        case .notDetermined:
            isLocating = false
        @unknown default:
            isLocating = false
        }
    }

    fileprivate func applyFailure(_ code: CLError.Code?) {
        isLocating = false
        if code == .denied {
            // iOS reports a denial through the error channel too when location
            // services are off system-wide.
            authorization = manager.authorizationStatus
        }
    }
}

// MARK: - CLLocationManagerDelegate

/// The delegate callbacks are `nonisolated` because `CLLocationManagerDelegate`
/// is not main-actor bound. Each one extracts a `Sendable` value and hops onto
/// the main actor; nothing captures the manager or the `CLLocation` itself.
extension LocationProvider: CLLocationManagerDelegate {
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let last = locations.last else { return }
        let point = GeoPoint(
            latitude: last.coordinate.latitude,
            longitude: last.coordinate.longitude
        )
        Task { @MainActor [weak self] in
            self?.apply(point)
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyAuthorization(status)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let code = (error as? CLError)?.code
        Task { @MainActor [weak self] in
            self?.applyFailure(code)
        }
    }
}
