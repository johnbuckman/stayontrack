import Foundation
import MapKit

/// OSM tile usage policy requires a valid, identifying User-Agent.
/// Personal-use app, so this points at John.
let osmUserAgent = "StayOnTrack/0.1 (+https://github.com/johnbuckman/stayontrack)"

/// On-disk tile cache at Application Support/OSMTiles/z/x/y.png.
///
/// Deliberately NOT in Caches: iOS may purge `.cachesDirectory` under storage
/// pressure, which would silently drop tiles a hiker needs offline. Application
/// Support survives app restarts and low-storage eviction, so tiles downloaded
/// for a route (or warmed by panning a frequently-hiked area) stay available.
/// One-time migration moves any tiles left behind in the old Caches location.
enum TileStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OSMTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateFromCachesIfNeeded(to: dir)
        excludeFromBackup(dir)   // tiles are re-downloadable; keep them out of iCloud/iTunes backups
        return dir
    }()

    /// Move a pre-existing Caches/OSMTiles cache into Application Support once,
    /// so upgrading users keep their already-downloaded tiles.
    private static func migrateFromCachesIfNeeded(to dir: URL) {
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OSMTiles", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        // Move each top-level zoom folder across; ignore anything already present.
        if let entries = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for entry in entries {
                let dest = dir.appendingPathComponent(entry.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: entry, to: dest)
                }
            }
        }
        try? fm.removeItem(at: old)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func fileURL(_ t: TileCoord) -> URL {
        root.appendingPathComponent("\(t.z)/\(t.x)/\(t.y).png")
    }

    static func exists(_ t: TileCoord) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(t).path)
    }

    static func read(_ t: TileCoord) -> Data? {
        try? Data(contentsOf: fileURL(t))
    }

    static func write(_ data: Data, _ t: TileCoord) {
        let url = fileURL(t)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Serves OSM raster tiles, disk-cache first. A cache miss fetches from OSM
/// (with the required User-Agent) and writes it to disk, so panning also
/// warms the cache. After the import-time pre-download the corridor is fully
/// offline — this only touches the network for tiles outside it.
final class OSMTileOverlay: MKTileOverlay {
    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        canReplaceMapContent = true          // hide Apple's basemap
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = TileMath.zoomRange.lowerBound
        maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let coord = TileCoord(z: path.z, x: path.x, y: path.y)
        if let cached = TileStore.read(coord) {
            result(cached, nil)
            return
        }
        var request = URLRequest(url: url(forTilePath: path))
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200 {
                TileStore.write(data, coord)
                result(data, nil)
            } else {
                result(data, error)
            }
        }.resume()
    }
}
