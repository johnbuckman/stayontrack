#if DEBUG
import Foundation
import MapKit
import os

/// Asks the real `MapTileOverlay` for a tile at every zoom level and logs what
/// came back, so "zooming out blanks the map" can be checked from the log
/// without anyone pinching a screen.
///
/// It exists because the blank-tile bugs were never in the magnifying code — they
/// were in whether MapKit asked for the tile at all (`minimumZ`/`maximumZ`). A
/// test of the maths in isolation passed happily while the map stayed blank, so
/// this drives the actual overlay object the map uses.
///
/// DEBUG only, and it never writes anything: it reads the cache and, where the
/// overlay would, fetches a tile the overlay would have fetched anyway.
enum TileSelfCheck {
    private static let log = Logger(subsystem: "com.johnbuckman.stayontrack",
                                    category: "tiles")

    static func run(at coordinate: CLLocationCoordinate2D, style: MapStyle) {
        let overlay = MapTileOverlay(style: style)
        let zooms = Array(overlay.minimumZ...min(overlay.maximumZ, 22))
        log.info("""
                 self-check [\(style.rawValue, privacy: .public)] \
                 z\(overlay.minimumZ)–\(zooms.last ?? 0) at \
                 \(coordinate.latitude, privacy: .public),\
                 \(coordinate.longitude, privacy: .public)
                 """)
        Task.detached {
            var blanks: [Int] = []
            for z in zooms {
                let path = MKTileOverlayPath(x: TileMath.tileX(lon: coordinate.longitude, z: z),
                                             y: TileMath.tileY(lat: coordinate.latitude, z: z),
                                             z: z,
                                             contentScaleFactor: 1)
                let bytes = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                    overlay.loadTile(at: path) { data, _ in c.resume(returning: data?.count ?? 0) }
                }
                if bytes == 0 { blanks.append(z) }
                log.info("  z\(z, privacy: .public): \(bytes, privacy: .public) bytes")
            }
            if blanks.isEmpty {
                log.info("self-check [\(style.rawValue, privacy: .public)]: OK, no blank zoom levels")
            } else {
                log.error("""
                          self-check [\(style.rawValue, privacy: .public)]: \
                          BLANK at z\(blanks.map(String.init).joined(separator: ","), privacy: .public)
                          """)
            }
        }
    }
}
#endif
