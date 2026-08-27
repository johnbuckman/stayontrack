import Foundation
import CoreLocation
import CryptoKit

/// An eatery near the trail, with how far along the route its closest approach
/// is (so we can predict what time you'll pass it).
struct TrailRestaurant: Identifiable, Codable, Equatable {
    var id: Int                     // OSM node id
    var name: String
    var kind: String                // restaurant / cafe / fast_food / …
    var lat: Double
    var lon: Double
    var routeDistance: Double       // metres along the route at closest approach
    var offset: Double              // metres from the trail

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var alongText: String { String(format: "%.1f km", routeDistance / 1000) }
}

/// Fetches eateries within ~200 m of the route from Overpass at import time and
/// caches them per-route so they're available offline on the hike.
enum RestaurantFinder {
    private static let corridor: CLLocationDistance = 200

    static func fetch(coords: [CLLocationCoordinate2D],
                      cumulative: [CLLocationDistance]) async -> [TrailRestaurant] {
        guard coords.count > 1 else { return [] }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let pad = 0.003
        let bbox = (s: lats.min()! - pad, w: lons.min()! - pad,
                    n: lats.max()! + pad, e: lons.max()! + pad)
        let query = """
        [out:json][timeout:25];
        (
          node["amenity"~"^(restaurant|cafe|fast_food|pub|bar)$"](\(bbox.s),\(bbox.w),\(bbox.n),\(bbox.e));
        );
        out;
        """
        guard let elements = try? await OverpassPOI.fetch(query: query) else { return [] }

        var out: [TrailRestaurant] = []
        for e in elements {
            guard let lat = e.lat, let lon = e.lon else { continue }
            let poi = CLLocation(latitude: lat, longitude: lon)
            // Closest approach of this POI to the route.
            var best = Double.greatestFiniteMagnitude
            var bestDist = 0.0
            for (i, c) in coords.enumerated() {
                let d = poi.distance(from: CLLocation(from: c))
                if d < best { best = d; bestDist = cumulative[i] }
            }
            guard best <= corridor else { continue }
            let name = e.tags?["name"] ?? "Restaurant"
            let kind = e.tags?["amenity"] ?? "restaurant"
            out.append(TrailRestaurant(id: e.id, name: name, kind: kind,
                                       lat: lat, lon: lon,
                                       routeDistance: bestDist, offset: best))
        }
        return dedupedByName(out.sorted { $0.routeDistance < $1.routeDistance })
    }

    /// OSM often carries the same eatery as more than one element (a node plus a
    /// building way, or duplicate imports), so the same name can appear twice.
    /// Keep the first of each name (the earliest along the route, since the input
    /// is sorted by `routeDistance`). Case/space-insensitive; unnamed entries are
    /// kept as-is.
    static func dedupedByName(_ list: [TrailRestaurant]) -> [TrailRestaurant] {
        var seen = Set<String>()
        var out: [TrailRestaurant] = []
        for r in list {
            let key = r.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty { out.append(r); continue }
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
}

/// Minimal Overpass node fetch (with tags) reusing the same mirror/retry policy
/// shape as `OverpassClient`, for point-of-interest queries.
enum OverpassPOI {
    struct Element: Decodable {
        let id: Int
        let lat: Double?
        let lon: Double?
        let tags: [String: String]?
    }
    private struct Payload: Decodable { let elements: [Element] }

    private static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        "https://overpass.openstreetmap.ru/api/interpreter"
    ]

    static func fetch(query: String) async throws -> [Element] {
        let body = "data=\(query)".data(using: .utf8)!
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            do {
                let (data, response) = try await URLSession.shared.upload(for: request, from: body)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
                    return payload.elements
                }
            } catch { continue }
        }
        return []
    }
}

/// Per-route disk cache for nearby restaurants (offline reuse).
enum RestaurantCache {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RestaurantCache", isDirectory: true)
    }
    static func key(for coords: [CLLocationCoordinate2D]) -> String {
        var hasher = SHA256()
        for c in coords {
            hasher.update(data: Data(String(format: "%.6f,%.6f;", c.latitude, c.longitude).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func load(_ key: String) -> [TrailRestaurant]? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TrailRestaurant].self, from: data)
    }
    static func save(_ key: String, _ items: [TrailRestaurant]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
