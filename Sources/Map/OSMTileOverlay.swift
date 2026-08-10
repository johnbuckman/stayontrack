import Foundation
import MapKit

/// OSM tile usage policy requires a valid, identifying User-Agent.
/// Personal-use app, so this points at John.
let osmUserAgent = "StayOnTrack/0.1 (+https://github.com/johnbuckman/stayontrack)"

/// On-disk tile cache at Caches/OSMTiles/z/x/y.png.
enum TileStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OSMTiles", isDirectory: true)
    }()

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
