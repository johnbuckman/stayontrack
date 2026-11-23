import Foundation

/// Turns noisy elevation into believable climb figures and slopes.
///
/// Two kinds of error were making the numbers wrong (checked Nov 2026 against
/// MapOut on six routes):
///   - noise counted as climb: GPS altitude and some DEM profiles jitter by
///     ±5–10 m from point to point, and summing every rise added it all up
///     (a recorded Hong Kong walk with 79 m of relief read +328 m; MapOut +73);
///   - gentle slopes dropped: the old "ignore rises under 1 m between points"
///     rule discarded steady climbs on densely drawn routes (a point every
///     ~10 m on a 5% slope rises 0.5 m per point), so some routes read low.
/// The fix is to average elevation over ±150 m along the track, then count a
/// climb or descent only once it exceeds 5 m from the last turning point
/// (hysteresis). Against MapOut: Pok Fu Lam plan 235 vs 241 m (was 555),
/// Drawn 21 Nov 361 vs 389 (was 324), recorded 21 Nov 361 vs 376, recorded
/// 5 Oct 407 vs 424, recorded 22 Nov 99 vs 73 (was 328), Murs 196 vs 246.
enum ElevationSmoothing {
    static let window: Double = 150          // metres either side
    static let threshold: Double = 5         // metres of change before it counts

    /// Moving average of elevation over ±`window` metres of track distance.
    /// `cumulative` is the distance from the start to each point. Points with
    /// no elevation stay nil and are skipped in the averages.
    static func smoothed(cumulative: [Double], elevations: [Double?],
                         window: Double = window) -> [Double?] {
        let n = min(cumulative.count, elevations.count)
        guard n > 0 else { return [] }
        var out = [Double?](repeating: nil, count: n)
        var lo = 0, hi = -1
        var sum = 0.0, count = 0
        for i in 0..<n {
            while hi + 1 < n && cumulative[hi + 1] - cumulative[i] <= window {
                hi += 1
                if let e = elevations[hi] { sum += e; count += 1 }
            }
            while cumulative[i] - cumulative[lo] > window {
                if let e = elevations[lo] { sum -= e; count -= 1 }
                lo += 1
            }
            out[i] = count > 0 ? sum / Double(count) : nil
        }
        return out
    }

    /// Total climb and descent, counting a change only once it exceeds
    /// `threshold` from the last turning point.
    static func climb(_ elevations: [Double?], threshold: Double = threshold)
    -> (up: Double, down: Double) {
        var up = 0.0, down = 0.0
        var ref: Double?
        for case let e? in elevations {
            guard let r = ref else { ref = e; continue }
            if e - r >= threshold { up += e - r; ref = e }
            else if r - e >= threshold { down += r - e; ref = e }
        }
        return (up, down)
    }

    /// Climb from raw points: smooth along the track, then count.
    static func climb(cumulative: [Double], elevations: [Double?]) -> (up: Double, down: Double) {
        climb(smoothed(cumulative: cumulative, elevations: elevations))
    }
}

/// The same idea for a walk in progress, where future points aren't known:
/// average over the last 2 × `window` metres walked (so the smoothing width
/// matches the route figure, at the cost of ~150 m of lag), then count with
/// the same hysteresis.
struct LiveClimbCounter {
    private var samples: [(dist: Double, ele: Double)] = []
    /// Hysteresis reference: the smoothed elevation at the last turning point.
    private(set) var reference: Double?
    private(set) var gain: Double = 0

    init(gain: Double = 0, reference: Double? = nil) {
        self.gain = gain
        self.reference = reference
    }

    mutating func add(distance: Double, elevation: Double) {
        samples.append((distance, elevation))
        let span = 2 * ElevationSmoothing.window
        while samples.count > 1, distance - samples[0].dist > span { samples.removeFirst() }
        let avg = samples.reduce(0) { $0 + $1.ele } / Double(samples.count)
        guard let r = reference else { reference = avg; return }
        if avg - r >= ElevationSmoothing.threshold { gain += avg - r; reference = avg }
        else if r - avg >= ElevationSmoothing.threshold { reference = avg }
    }

    /// After a pause or resume the old samples no longer describe where we are.
    mutating func resetWindow() { samples.removeAll() }
}
