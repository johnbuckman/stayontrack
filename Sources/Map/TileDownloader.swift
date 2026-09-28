import Foundation
import CoreLocation

struct TileProgress: Equatable {
    var done: Int
    var total: Int
    var isComplete: Bool { total > 0 && done >= total }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Pre-downloads the corridor of tiles around a route so the map works offline
/// (John hikes in airplane mode). Limited concurrency to stay a polite OSM
/// client. Already-cached tiles are skipped, so re-importing is cheap.
actor TileDownloader {
    private let maxConcurrent = 6

    /// Downloads every missing corridor tile for `style`, reporting progress on
    /// the main actor as it goes. The zoom range is the style's own
    /// (`cacheZooms` — topo goes a level deeper than standard), capped to what
    /// the style actually serves, and tiles land in the style's own cache.
    func download(coords: [CLLocationCoordinate2D],
                  style: MapStyle = .standard,
                  progress: @escaping @MainActor (TileProgress) -> Void) async {
        let all = TileMath.corridorTiles(for: coords, zooms: style.cacheZooms)
            .filter { $0.z <= style.maximumZ }
        let total = all.count
        let subdir = style.cacheSubdir
        let missing = all.filter { !TileStore.exists($0, subdir: subdir) }
        var done = total - missing.count

        await progress(TileProgress(done: done, total: total))
        guard !missing.isEmpty else { return }

        var index = 0
        while index < missing.count {
            let slice = Array(missing[index..<min(index + maxConcurrent, missing.count)])
            await withTaskGroup(of: Void.self) { group in
                for tile in slice {
                    group.addTask { await Self.fetch(tile, style: style) }
                }
                await group.waitForAll()
            }
            done += slice.count
            index += slice.count
            await progress(TileProgress(done: done, total: total))
        }
    }

    private static func fetch(_ tile: TileCoord, style: MapStyle) async {
        let template = style.urlTemplate
            .replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y))
        guard let url = URL(string: template) else { return }
        var request = URLRequest(url: url)
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            TileStore.write(data, tile, subdir: style.cacheSubdir)
        }
    }
}
