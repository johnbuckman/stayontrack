import Foundation
import CoreLocation
import CryptoKit

/// Caches the OSM intersection nodes for a route so we never re-hit Overpass for
/// the same hike. Keyed by a hash of the route's coordinates, stored as JSON in
/// Caches. The nodes are direction-independent, so junctions (which do depend on
/// travel direction) still recompute locally & instantly — including on Reverse.
enum IntersectionCache {
    private struct DTO: Codable { let lat: Double; let lon: Double; let degree: Int }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JunctionCache", isDirectory: true)
    }

    /// Stable key from the route geometry (independent of direction).
    static func key(for coords: [CLLocationCoordinate2D]) -> String {
        var hasher = SHA256()
        for c in coords {
            hasher.update(data: Data(String(format: "%.6f,%.6f;", c.latitude, c.longitude).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> [Intersection]? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let dtos = try? JSONDecoder().decode([DTO].self, from: data) else { return nil }
        return dtos.map {
            Intersection(coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                         degree: $0.degree)
        }
    }

    static func save(_ key: String, _ items: [Intersection]) {
        let dtos = items.map { DTO(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, degree: $0.degree) }
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
