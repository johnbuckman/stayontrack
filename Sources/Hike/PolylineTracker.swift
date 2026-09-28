import Foundation
import CoreLocation

/// Tracks how far off the planned route you are, and where along it you are.
///
/// Matching is constrained to a DISTANCE-based window of the route around your
/// last known progress (roughly the next kilometre ahead plus a little behind),
/// not the whole polyline. This is what keeps it correct on out-and-back and
/// looping routes: on such a route the return leg retraces the outbound leg —
/// often within a metre — so a global nearest-point search would happily snap
/// onto the coincident opposite leg (0 m away, but kilometres off in route
/// distance), reporting a sudden jump in progress and a spurious "off trail".
/// A leg that loops back kilometres away simply isn't inside the window.
///
/// A global re-acquisition only happens after you've been clearly lost for
/// several consecutive fixes, so a single noisy GPS fix can never teleport you
/// onto the wrong leg.
struct PolylineTracker {
    private let pts: [CLLocationCoordinate2D]
    private let eles: [Double?]
    private let cum: [Double]              // cumulative route distance per point (m)
    private var guessIndex = 0
    private var guessDistance = 0.0        // route distance of the last match (m)

    // Distance-based search window (metres of route distance) around the last
    // known progress. Wide enough to absorb GPS jitter and a paused fix, narrow
    // enough that a leg looping back kilometres away is never a candidate.
    private let lookBehind = 200.0
    private let lookAhead = 1000.0

    // Global re-acquisition fires only after SUSTAINED loss. On an overlapping
    // route a single transient must NOT trigger it, or it would snap onto the
    // coincident opposite leg.
    //
    // The threshold is deliberately the same 60 m at which `HikeSession` stops
    // announcing junctions. It used to be 150 m, which left a dead zone: leave
    // the trail and rejoin at a part whose distance from the STALE window lands
    // between 60 and 150 m, and the tracker never re-acquired while the session
    // refused to speak — turn directions were silently gone until the app was
    // killed and resumed. The coincident-leg protection is preserved by the
    // sustained-loss requirement plus `isClearlyBetter`.
    private let lostThreshold = 60.0      // metres off the windowed match
    private let lostFixesNeeded = 3
    private var lostStreak = 0

    // A global match must beat the windowed one by this much, and by this
    // factor, before we jump. A marginal improvement is far more likely to be
    // the opposite leg of an out-and-back than a genuine re-acquisition.
    private let reacquireMinGain = 30.0
    private let reacquireMaxRatio = 0.5

    // Two segments of a route that retraces itself sit within metres of each
    // other, so a global search can pick either. Within this tolerance, prefer
    // the candidate closest in ROUTE distance to where we thought we were —
    // you rejoin a trail near where you left it, not on the far leg.
    private let ambiguousMatchMeters = 10.0

    /// Result of matching a position to the route.
    struct Match {
        var offTrackMeters: CLLocationDistance
        var segmentIndex: Int
        var t: Double                 // 0...1 along the matched segment
        var elevation: Double?        // interpolated planned elevation at match
        /// True when this fix re-acquired the route globally, i.e. progress just
        /// jumped to a different part of the route. `HikeSession` uses it to
        /// re-arm the junctions that are now ahead again.
        var reacquired: Bool = false
    }

    init(points: [GPXPoint]) {
        self.pts = points.map(\.coordinate)
        self.eles = points.map(\.elevation)
        self.cum = Geo.cumulativeDistances(pts)
    }

    var isEmpty: Bool { pts.count < 2 }

    /// Position the search window at a known point along the route (used when
    /// resuming a hike from a checkpoint, so the first fix doesn't have to
    /// re-acquire from the start).
    mutating func seed(routeDistance d: Double) {
        guessDistance = max(0, d)
        var i = 0
        while i < pts.count - 2 && cum[i + 1] < guessDistance { i += 1 }
        guessIndex = i
        lostStreak = 0
    }

    mutating func match(_ p: CLLocationCoordinate2D) -> Match {
        guard pts.count >= 2 else {
            return Match(offTrackMeters: 0, segmentIndex: 0, t: 0, elevation: eles.first ?? nil)
        }

        let (lo, hi) = windowRange()
        var best = search(p, in: lo...hi)

        // Only re-scan the whole route once we've been clearly lost for several
        // consecutive fixes — never on a single transient (which on an
        // overlapping route would snap us onto the wrong, coincident leg).
        if best.offTrackMeters > lostThreshold {
            lostStreak += 1
            if lostStreak >= lostFixesNeeded, pts.count > 2 {
                let global = searchGlobal(p)
                if isClearlyBetter(global, than: best) {
                    best = global
                    best.reacquired = true
                }
                lostStreak = 0
            }
        } else {
            lostStreak = 0
        }

        guessIndex = best.segmentIndex
        let segLen = max(1, cum[best.segmentIndex + 1] - cum[best.segmentIndex])
        guessDistance = cum[best.segmentIndex] + best.t * segLen

        let e0 = eles[best.segmentIndex]
        let e1 = eles[best.segmentIndex + 1]
        best.elevation = interpolateElevation(e0, e1, best.t)
        return best
    }

    /// Segment index range whose route distance falls within
    /// [progress − lookBehind, progress + lookAhead]. Walks outward from the
    /// last match, so it costs O(window), not O(route).
    private func windowRange() -> (Int, Int) {
        let loD = guessDistance - lookBehind
        let hiD = guessDistance + lookAhead
        let maxSeg = pts.count - 2
        var lo = min(guessIndex, maxSeg)
        var hi = lo
        while lo > 0 && cum[lo] > loD { lo -= 1 }
        while hi < maxSeg && cum[hi] < hiD { hi += 1 }
        return (lo, hi)
    }

    /// Is a global candidate good enough to abandon the windowed match for?
    /// It has to be substantially closer in absolute terms AND by a wide margin
    /// proportionally — a 5 m improvement on a 70 m match means we're lost, not
    /// re-found, and jumping on it risks landing on the opposite leg.
    private func isClearlyBetter(_ candidate: Match, than current: Match) -> Bool {
        candidate.offTrackMeters < current.offTrackMeters - reacquireMinGain
            && candidate.offTrackMeters < current.offTrackMeters * reacquireMaxRatio
    }

    /// Nearest point on the WHOLE route, breaking near-ties in favour of the
    /// candidate closest to our current progress. Without the tie-break a route
    /// that retraces itself offers two equally good answers kilometres apart,
    /// and picking the wrong one reverses every turn instruction.
    private func searchGlobal(_ p: CLLocationCoordinate2D) -> Match {
        let maxSeg = pts.count - 2
        var best = search(p, in: 0...maxSeg)
        // Fixed before the loop: if it tracked `best` it would creep outward as
        // we accepted slightly-worse-but-closer candidates.
        let tolerance = best.offTrackMeters + ambiguousMatchMeters
        var bestGap = abs(routeDistance(of: best) - guessDistance)
        for i in 0...maxSeg {
            let (d, t) = Self.distanceToSegment(p, pts[i], pts[i + 1])
            guard d <= tolerance else { continue }
            let candidate = Match(offTrackMeters: d, segmentIndex: i, t: t, elevation: nil)
            let gap = abs(routeDistance(of: candidate) - guessDistance)
            if gap < bestGap {
                best = candidate
                bestGap = gap
            }
        }
        return best
    }

    /// Route distance (metres from the start) of a match.
    private func routeDistance(of m: Match) -> Double {
        let segLen = max(1, cum[m.segmentIndex + 1] - cum[m.segmentIndex])
        return cum[m.segmentIndex] + m.t * segLen
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
