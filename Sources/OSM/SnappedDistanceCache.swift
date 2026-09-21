import Foundation
import CoreLocation
import CryptoKit

/// Caches the OSM-snapped corrected distance for a route so we compute it once,
/// then read it instantly offline on every later load of the same hike. Keyed by
/// a hash of the route coordinates (direction-independent — the physical trail is
/// the same length either way). Separate schema tag from the junction cache so
/// changing the snapping method invalidates only this.
enum SnappedDistanceCache {
    private struct DTO: Codable { let distance: Double; let recovered: Int; let fellBack: Int }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnappedDistanceCache", isDirectory: true)
    }

    /// Bump when the snapping algorithm changes so stale results are ignored.
    private static let schema = "v1"

    static func key(for coords: [CLLocationCoordinate2D]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(schema.utf8))
        for c in coords {
            hasher.update(data: Data(String(format: "%.6f,%.6f;", c.latitude, c.longitude).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> RouteSnapper.Result? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        return RouteSnapper.Result(distance: dto.distance, recovered: dto.recovered, fellBack: dto.fellBack)
    }

    static func save(_ key: String, _ result: RouteSnapper.Result) {
        let dto = DTO(distance: result.distance, recovered: result.recovered, fellBack: result.fellBack)
        guard let data = try? JSONEncoder().encode(dto) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
