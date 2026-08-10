import Foundation
import CoreLocation

/// Tracks how far off the planned route you are, and where along it you are.
///
/// Uses a moving window around the last known position so it stays correct on
/// loops and switchbacks (a global nearest-point search would jump to the wrong
/// parallel leg). Falls back to a full scan only when the windowed match is far.
struct PolylineTracker {
    private let pts: [CLLocationCoordinate2D]
    private let eles: [Double?]
    private var guessIndex = 0
    private let window = 40

    /// Result of matching a position to the route.
    struct Match {
        var offTrackMeters: CLLocationDistance
        var segmentIndex: Int
        var t: Double                 // 0...1 along the matched segment
        var elevation: Double?        // interpolated planned elevation at match
    }

    init(points: [GPXPoint]) {
        self.pts = points.map(\.coordinate)
        self.eles = points.map(\.elevation)
    }

    var isEmpty: Bool { pts.count < 2 }

    mutating func match(_ p: CLLocationCoordinate2D) -> Match {
        guard pts.count >= 2 else {
            return Match(offTrackMeters: 0, segmentIndex: 0, t: 0, elevation: eles.first ?? nil)
        }
        let lo = max(0, guessIndex - window)
        let hi = min(pts.count - 2, guessIndex + window)

        var best = search(p, in: lo...hi)
        if best.offTrackMeters > 300, pts.count > 2 {
            best = search(p, in: 0...(pts.count - 2))   // global fallback
        }
        guessIndex = best.segmentIndex

        let e0 = eles[best.segmentIndex]
        let e1 = eles[best.segmentIndex + 1]
        best.elevation = interpolateElevation(e0, e1, best.t)
        return best
    }

    private func search(_ p: CLLocationCoordinate2D, in range: ClosedRange<Int>) -> Match {
        var best = Match(offTrackMeters: .greatestFiniteMagnitude, segmentIndex: range.lowerBound, t: 0)
        for i in range {
            let (d, t) = Self.distanceToSegment(p, pts[i], pts[i + 1])
            if d < best.offTrackMeters {
                best.offTrackMeters = d
                best.segmentIndex = i
                best.t = t
            }
        }
        return best
    }

    private func interpolateElevation(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        switch (a, b) {
        case let (a?, b?): return a + (b - a) * t
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// Perpendicular distance (metres) from `p` to segment a→b, plus the
    /// projection parameter t. Uses a local equirectangular approximation
    /// centred on `a` — accurate at trail scale.
    static func distanceToSegment(_ p: CLLocationCoordinate2D,
                                  _ a: CLLocationCoordinate2D,
                                  _ b: CLLocationCoordinate2D) -> (CLLocationDistance, Double) {
        let R = 6_371_000.0
        let latRef = a.latitude * .pi / 180
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            let x = (c.longitude - a.longitude) * .pi / 180 * cos(latRef) * R
            let y = (c.latitude - a.latitude) * .pi / 180 * R
            return (x, y)
        }
        let (bx, by) = xy(b)
        let (px, py) = xy(p)
        let len2 = bx * bx + by * by
        let t = len2 > 0 ? max(0, min(1, (px * bx + py * by) / len2)) : 0
        let cx = bx * t, cy = by * t
        return (hypot(px - cx, py - cy), t)
    }
}
