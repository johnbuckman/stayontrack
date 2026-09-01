import Foundation
import CoreLocation
import CryptoKit

/// A public toilet near the trail, with how far along the route its closest
/// approach is (so we can predict what time you'll pass it) — the same shape as
/// `TrailRestaurant`.
struct TrailToilet: Identifiable, Codable, Equatable {
    var id: Int                     // OSM element id
    var name: String                // usually empty in OSM; defaulted to "Public toilet"
    var lat: Double
    var lon: Double
    var routeDistance: Double       // metres along the route at closest approach
    var offset: Double              // metres from the trail

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var alongText: String { String(format: "%.1f km", routeDistance / 1000) }
}

/// Fetches public toilets within ~150 m of the route from Overpass at import
/// time and caches them per-route so they're available offline on the hike.
/// Mirrors `RestaurantFinder` and shares its `OverpassPOI` transport.
enum ToiletFinder {
    private static let corridor: CLLocationDistance = 150

    static func fetch(coords: [CLLocationCoordinate2D],
                      cumulative: [CLLocationDistance]) async -> [TrailToilet] {
        guard coords.count > 1 else { return [] }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let pad = 0.003
        let bbox = (s: lats.min()! - pad, w: lons.min()! - pad,
                    n: lats.max()! + pad, e: lons.max()! + pad)
        // Toilets are tagged on nodes and on building/area ways; `nwr` + `out center`
        // returns a representative point for ways too.
        let query = """
        [out:json][timeout:25];
        (
          nwr["amenity"="toilets"](\(bbox.s),\(bbox.w),\(bbox.n),\(bbox.e));
        );
        out center;
        """
        guard let elements = try? await OverpassPOI.fetch(query: query) else { return [] }

        var out: [TrailToilet] = []
        for e in elements {
            guard let lat = e.lat ?? e.center?.lat, let lon = e.lon ?? e.center?.lon else { continue }
            let poi = CLLocation(latitude: lat, longitude: lon)
            var best = Double.greatestFiniteMagnitude
            var bestDist = 0.0
            for (i, c) in coords.enumerated() {
                let d = poi.distance(from: CLLocation(from: c))
                if d < best { best = d; bestDist = cumulative[i] }
            }
            guard best <= corridor else { continue }
            let name = e.tags?["name"] ?? "Public toilet"
            out.append(TrailToilet(id: e.id, name: name, lat: lat, lon: lon,
                                   routeDistance: bestDist, offset: best))
        }
        return dedupedByProximity(out.sorted { $0.routeDistance < $1.routeDistance })
    }

    /// OSM often carries the same toilet as more than one element (a node plus a
    /// building way). Names are usually empty, so dedupe geographically: drop any
    /// entry within ~20 m of one already kept.
    static func dedupedByProximity(_ list: [TrailToilet]) -> [TrailToilet] {
        var kept: [TrailToilet] = []
        for t in list {
            let dup = kept.contains { k in
                CLLocation(latitude: k.lat, longitude: k.lon)
                    .distance(from: CLLocation(latitude: t.lat, longitude: t.lon)) < 20
            }
            if !dup { kept.append(t) }
        }
        return kept
    }
}

/// Per-route disk cache for nearby toilets (offline reuse), mirroring
/// `RestaurantCache`.
enum ToiletCache {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToiletCache", isDirectory: true)
    }
    static func key(for coords: [CLLocationCoordinate2D]) -> String {
        var hasher = SHA256()
        for c in coords {
            hasher.update(data: Data(String(format: "%.6f,%.6f;", c.latitude, c.longitude).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func load(_ key: String) -> [TrailToilet]? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TrailToilet].self, from: data)
    }
    static func save(_ key: String, _ items: [TrailToilet]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
