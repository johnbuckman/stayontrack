import Foundation
import CoreLocation

/// A crash-recovery snapshot of an in-progress hike. Written periodically while
/// hiking and deleted on a clean End, so if the app is killed mid-hike (crash,
/// OS jetsam, force-quit) the next launch can offer to pick up where it left off.
///
/// The planned route itself is NOT stored here — `RouteModel` already persists
/// the last-loaded GPX (`last-hike.gpx`) and restores it on launch. This only
/// carries the live hike state (recorded track + running stats) that would
/// otherwise be lost.
struct HikeCheckpoint: Codable {
    struct Fix: Codable {
        var lat: Double
        var lon: Double
        var ele: Double?
        var t: Date
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        init(_ p: RecordedPoint) {
            lat = p.coordinate.latitude; lon = p.coordinate.longitude
            ele = p.elevation; t = p.time
        }
        var recordedPoint: RecordedPoint {
            RecordedPoint(coordinate: coordinate, elevation: ele, time: t)
        }
    }

    var routeName: String
    var reversed: Bool
    var startDate: Date
    var savedAt: Date
    var distanceWalked: Double
    var elevationGain: Double
    var offTrackMeters: Double
    var walkerRouteDistance: Double
    var lastElevation: Double?
    var recorded: [Fix]
}

/// On-disk store for the single active-hike checkpoint.
enum HikeCheckpointStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hike-checkpoint.json")
    }

    static func save(_ checkpoint: HikeCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> HikeCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HikeCheckpoint.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
