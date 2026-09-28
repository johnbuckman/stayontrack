import Foundation
import CoreLocation

/// A single OSM raster tile address.
struct TileCoord: Hashable {
    let z: Int
    let x: Int
    let y: Int
}

/// Slippy-map math + corridor tile enumeration (Web Mercator, EPSG:3857).
enum TileMath {
    /// Zoom levels we cache for offline use: overview down to trail detail.
    /// This is the floor every style shares; a style may cache deeper (see
    /// `MapStyle.cacheZooms`).
    static let zoomRange: ClosedRange<Int> = 12...16

    /// How far either side of the route we cache (metres). Comfortably beyond
    /// the 100 m off-trail threshold so straying never hits a blank tile.
    static let corridorBufferMeters: Double = 600

    /// Zoom at and above which the corridor narrows. Each zoom level quadruples
    /// the tile count, so caching z17 at the full 600 m would roughly triple a
    /// route's download for detail you only ever look at right around the path.
    static let detailZoom = 17

    /// Corridor half-width at `detailZoom` and deeper. 200 m is chosen for the
    /// tile grid, not as a round number: a z17 tile is ~216 m across at Alpine
    /// latitudes, so 200 m rounds to a ONE-tile margin (three tiles wide, ≥216 m
    /// of guaranteed cover either side of the path) where 250 m would round up
    /// to two and cache 75% more. Beyond it, `TileUpscaler` fills in from z16.
    static let detailCorridorBufferMeters: Double = 200

    /// Corridor half-width to cache at a given zoom.
    static func bufferMeters(for z: Int) -> Double {
        z >= detailZoom ? detailCorridorBufferMeters : corridorBufferMeters
    }

    static func tileX(lon: Double, z: Int) -> Int {
        let n = Double(1 << z)
        return Int(floor((lon + 180.0) / 360.0 * n))
    }

    static func tileY(lat: Double, z: Int) -> Int {
        let n = Double(1 << z)
        let latRad = lat * .pi / 180.0
        return Int(floor((1.0 - asinh(tan(latRad)) / .pi) / 2.0 * n))
    }

    /// Ground size of one tile in metres at a given latitude/zoom.
    static func tileMeters(lat: Double, z: Int) -> Double {
        let latRad = lat * .pi / 180.0
        let metersPerPixel = 156543.03392 * cos(latRad) / Double(1 << z)
        return metersPerPixel * 256.0
    }

    /// All tiles needed to cover a buffered corridor around the route,
    /// across `zoomRange`. The route is densified first so long straight
    /// segments don't skip tiles between points.
    /// `bufferMeters` overrides the per-zoom corridor width; leave it nil to use
    /// `bufferMeters(for:)`, which narrows the corridor at the detail zooms.
    static func corridorTiles(for coords: [CLLocationCoordinate2D],
                              zooms: ClosedRange<Int> = zoomRange,
                              bufferMeters: Double? = nil) -> [TileCoord] {
        guard !coords.isEmpty else { return [] }
        let dense = densify(coords, maxGap: 100)
        var tiles = Set<TileCoord>()

        for z in zooms {
            let n = 1 << z
            let buffer = bufferMeters ?? Self.bufferMeters(for: z)
            for c in dense {
                let perTile = tileMeters(lat: c.latitude, z: z)
                let buf = max(0, Int(ceil(buffer / perTile)))
                let cx = tileX(lon: c.longitude, z: z)
                let cy = tileY(lat: c.latitude, z: z)
                for dx in -buf...buf {
                    for dy in -buf...buf {
                        let x = cx + dx, y = cy + dy
                        if x >= 0, y >= 0, x < n, y < n {
                            tiles.insert(TileCoord(z: z, x: x, y: y))
                        }
                    }
                }
            }
        }
        return Array(tiles)
    }

    /// Inserts intermediate points so no gap exceeds `maxGap` metres.
    static func densify(_ coords: [CLLocationCoordinate2D],
                        maxGap: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 1 else { return coords }
        var out: [CLLocationCoordinate2D] = [coords[0]]
        for i in 1..<coords.count {
            let a = coords[i - 1], b = coords[i]
            let d = CLLocation(from: a).distance(from: CLLocation(from: b))
            if d > maxGap {
                let steps = Int(ceil(d / maxGap))
                for s in 1..<steps {
                    let t = Double(s) / Double(steps)
                    out.append(CLLocationCoordinate2D(
                        latitude: a.latitude + (b.latitude - a.latitude) * t,
                        longitude: a.longitude + (b.longitude - a.longitude) * t))
                }
            }
            out.append(b)
        }
        return out
    }
}
