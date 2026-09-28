import Foundation
import MapKit
import UIKit

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

    /// Zoom levels pre-cached for offline use at import.
    ///
    /// Topo goes all the way to z17 — it is the map John actually hikes on, and
    /// z17 is where the contour lines become readable. Standard stops at z16;
    /// beyond that it falls back to upscaled z16 tiles (`TileUpscaler`), which
    /// is fine for a map he only glances at. z17 quadruples the tile count, so
    /// it is cached over a narrower corridor — see `TileMath.bufferMeters(for:)`.
    var cacheZooms: ClosedRange<Int> {
        switch self { case .standard: return 12...16; case .topo: return 12...17 }
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
        // Short: on the trail there is no network at all, and we'd rather show
        // the upscaled fallback promptly than leave the map blank for 60 s.
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200 {
                TileStore.write(data, coord, subdir: subdir)
                result(data, nil)
            } else if let standIn = self?.upscaledAncestor(of: coord) {
                // Offline (or the tile simply isn't served at this zoom): show
                // the best cached tile we do have, stretched to fit.
                result(standIn, nil)
            } else {
                result(data, error)
            }
        }.resume()
    }

    /// Nearest cached lower-zoom tile covering `coord`, cropped to the right
    /// quadrant and blown up to tile size. Nil if nothing within reach is
    /// cached. Never stored — see `TileUpscaler`.
    private func upscaledAncestor(of coord: TileCoord) -> Data? {
        let subdir = style.cacheSubdir
        for levelsUp in 1...TileUpscaler.maxLevelsUp {
            let z = coord.z - levelsUp
            guard z >= minimumZ else { break }
            let parent = TileUpscaler.ancestor(of: coord, levelsUp: levelsUp)
            guard let data = TileStore.read(parent, subdir: subdir),
                  let image = UIImage(data: data) else { continue }
            let grid = 1 << levelsUp                       // tiles per ancestor edge
            return TileUpscaler.upscale(image,
                                        gridSize: grid,
                                        x: coord.x - (parent.x << levelsUp),
                                        y: coord.y - (parent.y << levelsUp),
                                        to: tileSize)
        }
        return nil
    }
}
