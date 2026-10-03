import Foundation
import MapKit
import UIKit
import os

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
    /// The deepest zoom this server has REAL tiles for. Verified by probing:
    /// OSM serves z19 and 400s at z20; OpenTopoMap stops at z17 and answers
    /// every deeper request with HTTP 200 and the same byte-identical 4,343-byte
    /// placeholder PNG at every coordinate. So a deeper request must never be
    /// made — it would cache a dud on top of a perfectly good magnified tile.
    var serverMaximumZ: Int {
        switch self { case .standard: return 19; case .topo: return 17 }
    }

    /// The deepest zoom the overlay CLAIMS to cover, past every server's real
    /// limit. MapKit will not request a tile above an overlay's `maximumZ`, and
    /// its renderer draws nothing up there, so capping the overlay at the
    /// server's true limit is what left the map blank when you zoomed in — the
    /// fallback never even got asked. We claim these levels and magnify a
    /// shallower tile ourselves.
    ///
    /// Set beyond anything MapKit will actually ask for, on purpose. Any finite
    /// cap is a zoom depth at which the map goes blank again, and the whole
    /// point is that there should not be one. Magnifying a tile 8 levels is a
    /// coloured smear, but a smear still says "you are on a green slope"; a
    /// blank says nothing.
    static let displayMaximumZ = 25

    /// Zoom levels pre-cached for offline use at import.
    ///
    /// Topo goes all the way to z17 — it is the map John actually hikes on, and
    /// z17 is where the contour lines become readable. Standard stops at z16;
    /// beyond that it falls back to upscaled z16 tiles (`TileUpscaler`), which
    /// is fine for a map he only glances at. z17 quadruples the tile count, so
    /// it is cached over a narrower corridor — see `TileMath.bufferMeters(for:)`.
    var cacheZooms: ClosedRange<Int> {
        switch self { case .standard: return 0...16; case .topo: return 0...17 }
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
    /// Memoised cache directories. **The lock is not optional.** Tiles are read
    /// and written from several threads at once — the downloader's task group,
    /// URLSession's callback queue, the magnifier — and every one of them goes
    /// through `root(_:)`. Mutating this dictionary unsynchronised corrupts it
    /// and the app dies with an `objc doesNotRecognizeSelector` inside
    /// `Dictionary.setValue`, which looks nothing like a threading bug.
    private static let rootsLock = NSLock()
    private static var roots: [String: URL] = [:]

    static func root(_ subdir: String) -> URL {
        rootsLock.lock()
        defer { rootsLock.unlock() }
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

/// Serves raster tiles for a `MapStyle`, disk-cache first.
///
/// Three things happen here beyond a plain cache-then-fetch, all so the map is
/// never blank:
///
/// 1. We claim zoom levels deeper than the server actually has
///    (`displayMaximumZ`) and synthesise them by magnifying a shallower cached
///    tile, because MapKit draws nothing above an overlay's `maximumZ`.
/// 2. Above `style.serverMaximumZ` we never touch the network — OpenTopoMap
///    answers those with a placeholder, and caching it would be worse than the
///    magnified tile we can make ourselves.
/// 3. Within the server's range, a missing tile shows a magnified stand-in
///    IMMEDIATELY and fetches the real one in the background, swapping it in
///    when it lands. Waiting on the network first means staring at nothing.
final class MapTileOverlay: MKTileOverlay {
    let style: MapStyle

    /// The renderer drawing us, so a late-arriving real tile can replace the
    /// magnified stand-in shown in its place. Set by `RouteMapView`.
    weak var renderer: MKTileOverlayRenderer?

    /// Diagnostics for the one failure that matters: a tile we could not draw
    /// anything for. Watch it with
    /// `log stream --predicate 'subsystem == "com.johnbuckman.stayontrack"' --level debug`
    private static let log = Logger(subsystem: "com.johnbuckman.stayontrack", category: "tiles")

    private let lock = NSLock()
    private var inFlight = Set<TileCoord>()
    private var refreshScheduled = false

    /// How long to gather freshly-arrived tiles before refreshing the map, so a
    /// screenful of them costs one redraw instead of thirty.
    private let refreshDebounce: TimeInterval = 1.2

    init(style: MapStyle) {
        self.style = style
        super.init(urlTemplate: style.urlTemplate)
        canReplaceMapContent = true          // hide Apple's basemap
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = TileMath.zoomRange.lowerBound
        maximumZ = MapStyle.displayMaximumZ
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let coord = TileCoord(z: path.z, x: path.x, y: path.y)
        if let cached = TileStore.read(coord, subdir: style.cacheSubdir) {
            result(cached, nil)
            return
        }

        // Deeper than the server has anything real: magnify, never request.
        if coord.z > style.serverMaximumZ {
            magnify(coord, result: result)
            return
        }
        Self.log.debug("fetch z\(coord.z) \(coord.x)/\(coord.y) [\(self.style.rawValue, privacy: .public)]")

        // In range but not cached. Show a magnified stand-in now if we can, and
        // fetch the real tile to replace it; otherwise just wait for the fetch.
        if let standIn = upscaledAncestor(of: coord) {
            result(standIn, nil)
            fetch(coord) { [weak self] data, _ in
                if data != nil { self?.scheduleRefresh() }
            }
        } else {
            fetch(coord) { [weak self] data, error in
                if data == nil { self?.reportBlank(coord, why: "fetch failed, nothing to magnify") }
                result(data, error)
            }
        }
    }

    // MARK: Magnifying a shallower tile

    /// Serve `coord` by blowing up the deepest cached tile above it. If nothing
    /// is cached — we're outside the pre-downloaded corridor — fetch the deepest
    /// tile the server genuinely has and magnify that instead.
    private func magnify(_ coord: TileCoord, result: @escaping (Data?, Error?) -> Void) {
        if let standIn = upscaledAncestor(of: coord) {
            result(standIn, nil)
            return
        }
        let levelsUp = coord.z - style.serverMaximumZ
        guard levelsUp >= 1, levelsUp <= TileUpscaler.maxLevelsUp else {
            reportBlank(coord, why: "z\(coord.z) is \(levelsUp) levels above the server cap")
            result(nil, nil)
            return
        }
        fetch(TileUpscaler.ancestor(of: coord, levelsUp: levelsUp)) { [weak self] data, error in
            guard let self else { result(nil, error); return }
            let standIn = self.upscaledAncestor(of: coord)
            if standIn == nil { self.reportBlank(coord, why: "no ancestor cached and none fetchable") }
            result(standIn, standIn == nil ? error : nil)
            // One ancestor covers up to 16 tiles at this depth, so the siblings
            // were turned away empty while this fetch was in flight. Redraw now
            // it is cached. Only on success — refreshing after a failure would
            // retry forever while offline.
            if data != nil { self.scheduleRefresh() }
        }
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

    // MARK: Fetching

    private func tileURL(_ t: TileCoord) -> URL? {
        URL(string: style.urlTemplate
            .replacingOccurrences(of: "{z}", with: String(t.z))
            .replacingOccurrences(of: "{x}", with: String(t.x))
            .replacingOccurrences(of: "{y}", with: String(t.y)))
    }

    /// Download `coord` and cache it. Coalesces duplicate requests for the same
    /// tile, which `reloadData` would otherwise multiply.
    private func fetch(_ coord: TileCoord, completion: @escaping (Data?, Error?) -> Void) {
        guard let url = tileURL(coord) else { completion(nil, nil); return }
        lock.lock()
        let alreadyFetching = inFlight.contains(coord)
        if !alreadyFetching { inFlight.insert(coord) }
        lock.unlock()
        guard !alreadyFetching else { completion(nil, nil); return }

        var request = URLRequest(url: url)
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        // Short: on the trail there is no network at all, and a stand-in is
        // already on screen, so there is nothing to gain by waiting longer.
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { completion(nil, error); return }
            self.lock.lock(); self.inFlight.remove(coord); self.lock.unlock()
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                TileStore.write(data, coord, subdir: self.style.cacheSubdir)
                completion(data, nil)
            } else {
                completion(nil, error)
            }
        }.resume()
    }

    /// A tile we could draw nothing for — the symptom the user sees as a hole
    /// in the map. Logged at error level so it stands out in Console without
    /// enabling debug logging.
    private func reportBlank(_ coord: TileCoord, why: String) {
        Self.log.error("BLANK TILE z\(coord.z) \(coord.x)/\(coord.y) [\(self.style.rawValue)]: \(why)")
    }

    /// Ask the renderer to redraw once the dust settles, so real tiles replace
    /// the magnified stand-ins they were standing in for.
    ///
    /// `reloadData` rather than `setNeedsDisplay(in:)`: the renderer keeps its
    /// own decoded-tile cache, and only reloading discards it — a plain redraw
    /// would faithfully re-present the blurry tile. Debounced because a
    /// screenful of tiles arrives at once.
    private func scheduleRefresh() {
        lock.lock()
        let already = refreshScheduled
        refreshScheduled = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounce) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.refreshScheduled = false; self.lock.unlock()
            self.renderer?.reloadData()
        }
    }
}
