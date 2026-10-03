import Foundation
import UIKit

/// Builds a stand-in tile by blowing up the matching patch of a lower-zoom
/// ("ancestor") tile we already have on disk.
///
/// Why this exists: the corridor pre-download only caches a limited zoom range,
/// and the hike happens in airplane mode. Zoom in past the deepest cached level
/// and MapKit asks for a tile that is neither on disk nor fetchable, and the map
/// goes blank — precisely when you're peering at the detail. A blurry map beats
/// no map, so we crop the quadrant of the nearest cached ancestor that covers
/// the requested tile and scale it up to tile size.
///
/// The result is deliberately NOT written back to the tile cache: it is a
/// rendering fallback, not data, and caching it would mean a later online visit
/// keeps serving mush instead of fetching the real tile.
enum TileUpscaler {
    /// How many zoom levels up we'll look for something to magnify.
    ///
    /// Generous on purpose. Each level quarters the source area, so deep down
    /// the patch is only a few pixels and the result is coloured fog — but fog
    /// still shows the shape of the terrain, and the alternative at that depth
    /// is a blank screen. A tight limit here is just another way to make the
    /// map disappear when you zoom too far, which is the bug this exists to
    /// prevent. The search stops at the overlay's `minimumZ` anyway.
    static let maxLevelsUp = 14

    /// The ancestor `levelsUp` zoom levels above `t` (the tile that contains it).
    static func ancestor(of t: TileCoord, levelsUp: Int) -> TileCoord {
        TileCoord(z: t.z - levelsUp, x: t.x >> levelsUp, y: t.y >> levelsUp)
    }

    /// Crop `image` to the sub-square at (`x`, `y`) of an `n`×`n` grid and scale
    /// that to `size`. Returns PNG data, which is what `MKTileOverlay` wants.
    static func upscale(_ image: UIImage, gridSize n: Int, x: Int, y: Int,
                        to size: CGSize) -> Data? {
        guard let cg = image.cgImage, n > 0 else { return nil }
        let w = CGFloat(cg.width) / CGFloat(n)
        let h = CGFloat(cg.height) / CGFloat(n)
        let rect = CGRect(x: (w * CGFloat(x)).rounded(.down),
                          y: (h * CGFloat(y)).rounded(.down),
                          width: max(1, w.rounded(.up)),
                          height: max(1, h.rounded(.up)))
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !rect.isEmpty, let patch = cg.cropping(to: rect) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                 // we want size in pixels, not points
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let out = renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: patch).draw(in: CGRect(origin: .zero, size: size))
        }
        return out.pngData()
    }
}
