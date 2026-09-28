import Foundation
import CoreLocation

/// Real GPS for a live hike. Keeps updating with the screen off / app in the
/// background (so voice turns and the off-trail tone still fire in your pocket),
/// tuned for battery on a multi-hour walk. Used only when Simulate is off.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    /// Each fix: coordinate, altitude (nil unless valid), timestamp.
    var onLocation: ((CLLocationCoordinate2D, Double?, Date) -> Void)?
    @Published private(set) var denied = false
    /// Device compass heading in degrees (true north), for the on-map compass
    /// needle. Nil until the first reading (and on hardware without a compass,
    /// e.g. the Mac Catalyst dev build).
    @Published private(set) var heading: Double?

    private let manager = CLLocationManager()
    private var wantUpdates = false
    /// The heading-up map mode wants the compass even when no hike is running
    /// (and the compass, unlike GPS, needs no authorization).
    private var wantHeading = false

    override init() {
        super.init()
        manager.delegate = self
        // Best fix without the extra drain of BestForNavigation; a small
        // distance filter and the fitness activity type let the OS coalesce
        // updates to save battery on a long hike.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        wantUpdates = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            denied = true
        @unknown default:
            break
        }
    }

    func stop() {
        wantUpdates = false
        #if !targetEnvironment(macCatalyst)
        manager.allowsBackgroundLocationUpdates = false
        #endif
        manager.stopUpdatingLocation()
        if !wantHeading { stopHeadingUpdates() }
    }

    /// Does this device have a magnetometer at all? False on the Mac Catalyst
    /// dev build, where the map can only be north-up.
    var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    /// Compass only, no GPS — for rotating the map to the phone's facing
    /// direction outside a hike. No-op where there's no magnetometer (the Mac
    /// Catalyst dev build), which leaves `heading` nil and the map north-up.
    func startHeading() {
        wantHeading = true
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 3            // degrees
        manager.startUpdatingHeading()
    }

    /// Stops the compass unless a running hike still needs it for the needle.
    func stopHeading() {
        wantHeading = false
        guard !wantUpdates else { return }
        stopHeadingUpdates()
    }

    private func stopHeadingUpdates() {
        manager.stopUpdatingHeading()
        heading = nil
    }

    private func beginUpdates() {
        denied = false
        #if !targetEnvironment(macCatalyst)
        // Keep tracking while backgrounded / screen-locked (needs the "location"
        // background mode, declared in Info.plist).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 3            // degrees
            manager.startUpdatingHeading()
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        let coord = loc.coordinate
        // Pass nil elevation → the hike samples the planned profile (smoother
        // than noisy GPS altitude and consistent with the elevation chart).
        let time = loc.timestamp
        Task { @MainActor in self.onLocation?(coord, nil, time) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Prefer true heading; it's -1 until calibrated, then fall back to magnetic.
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard h >= 0 else { return }
        Task { @MainActor in self.heading = h }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.wantUpdates { self.beginUpdates() }
            case .denied, .restricted:
                self.denied = true
            default:
                break
            }
        }
    }
}
