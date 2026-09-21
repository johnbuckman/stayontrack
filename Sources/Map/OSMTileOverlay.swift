import Foundation
import MapKit

/// OSM tile usage policy requires a valid, identifying User-Agent.
/// Personal-use app, so this points at John. Also sent to OpenTopoMap.
let osmUserAgent = "StayOnTrack/0.1 (+https://github.com/johnbuckman/stayontrack)"

/// A basemap style. `standard` is the plain OSM raster; `topo` is OpenTopoMap,
/// which bakes **elevation contour lines + hillshading** into the tiles — the
/// "elevation lines on the map" the hiker can toggle to. Each style keeps its
/// own on-disk tile cache so switching never re-downloads the other.
enum MapStyle: String, CaseIterable, Codable {
    case standard, topo

    /// OpenTopoMap serves round-robin from a/b/c; one host is fine for our volume.
    var urlTemplate: String {
        switch self {
        case .standard: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .topo:     return "https://a.tile.opentopomap.org/{z}/{x}/{y}.png"
        }
    }
    var cacheSubdir: String {
        switch self { case .standard: return "OSMTiles"; case .topo: return "TopoTiles" }
    }
    /// OpenTopoMap's tiles stop at z17; OSM goes to z19.
    var maximumZ: Int {
        switch self { case .standard: return 19; case .topo: return 17 }
    }
}

/// On-disk tile cache at Application Support/<subdir>/z/x/y.png, one subdir per
/// `MapStyle`.
///
/// Deliberately NOT in Caches: iOS may purge `.cachesDirectory` under storage
/// pressure, which would silently drop tiles a hiker needs offline. Application
/// Support survives app restarts and low-storage eviction, so tiles downloaded
/// for a route (or warmed by panning a frequently-hiked area) stay available.
/// One-time migration moves any tiles left behind in the old Caches location.
enum TileStore {
    private static var roots: [String: URL] = [:]

    static func root(_ subdir: String) -> URL {
        if let r = roots[subdir] { return r }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if subdir == "OSMTiles" { migrateFromCachesIfNeeded(to: dir) }
        excludeFromBackup(dir)   // tiles are re-downloadable; keep them out of iCloud/iTunes backups
        roots[subdir] = dir
        return dir
    }

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

    static func fileURL(_ t: TileCoord, subdir: String = "OSMTiles") -> URL {
        root(subdir).appendingPathComponent("\(t.z)/\(t.x)/\(t.y).png")
    }

    static func exists(_ t: TileCoord, subdir: String = "OSMTiles") -> Bool {
        FileManager.default.fileExists(atPath: fileURL(t, subdir: subdir).path)
    }

    static func read(_ t: TileCoord, subdir: String = "OSMTiles") -> Data? {
        try? Data(contentsOf: fileURL(t, subdir: subdir))
    }

    static func write(_ data: Data, _ t: TileCoord, subdir: String = "OSMTiles") {
        let url = fileURL(t, subdir: subdir)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Serves raster tiles for a `MapStyle`, disk-cache first. A cache miss fetches
/// from the style's server (with the required User-Agent) and writes it to the
/// style's cache subdir, so panning also warms the cache. After the import-time
/// pre-download the corridor is fully offline — this only touches the network
/// for tiles outside it.
final class MapTileOverlay: MKTileOverlay {
    let style: MapStyle

    init(style: MapStyle) {
        self.style = style
        super.init(urlTemplate: style.urlTemplate)
        canReplaceMapContent = true          // hide Apple's basemap
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = TileMath.zoomRange.lowerBound
        maximumZ = style.maximumZ
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let coord = TileCoord(z: path.z, x: path.x, y: path.y)
        let subdir = style.cacheSubdir
        if let cached = TileStore.read(coord, subdir: subdir) {
            result(cached, nil)
            return
        }
        var request = URLRequest(url: url(forTilePath: path))
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200 {
                TileStore.write(data, coord, subdir: subdir)
                result(data, nil)
            } else {
                result(data, error)
            }
        }.resume()
    }
}
