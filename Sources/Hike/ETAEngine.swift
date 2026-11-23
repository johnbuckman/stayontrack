import Foundation
import CoreLocation

/// Predicts remaining time on the planned route using Tobler's hiking function,
/// grade-adjusted from the GPX elevation profile. Precomputed once at start;
/// `calculatedRemaining(fromDistance:)` returns seconds left from any point.
///
/// Tobler: walking speed W = 6·exp(-3.5·|slope + 0.05|) km/h.
struct ETAEngine {
    let totalDistance: CLLocationDistance
    private let cumulativeDistance: [CLLocationDistance]
    private let cumulativeTime: [TimeInterval]     // predicted seconds to reach each point
    private let segTime: [TimeInterval]

    /// `distanceScale` stretches every segment's horizontal length (default 1 =
    /// unchanged). Used for the pre-start estimate, where the OSM-snapped route is
    /// longer than the raw GPX sum: the recovered length is extra winding at
    /// roughly the same grades, so scaling distance grows the predicted time too
    /// while softening slopes only slightly. Live tracking keeps scale 1 so its
    /// lookups stay in real GPX metres.
    init(travelPoints: [GPXPoint], distanceScale: Double = 1) {
        let coords = travelPoints.map(\.coordinate)
        var cumDist = Geo.cumulativeDistances(coords)
        if distanceScale != 1 { cumDist = cumDist.map { $0 * distanceScale } }
        // Smooth the elevation profile first (±150 m along the track, the same
        // smoothing as the climb figure) — raw GPS / DEM elevation jitters, and
        // Tobler's exponential slope penalty turns that noise into extra time
        // (Pok Fu Lam read 2h55 against MapOut's 2h05). Slope is then clamped.
        let ele = ElevationSmoothing.smoothed(cumulative: Geo.cumulativeDistances(coords),
                                              elevations: travelPoints.map(\.elevation))
        var segT: [TimeInterval] = []
        var cumT: [TimeInterval] = [0]

        if coords.count > 1 {
            for i in 1..<coords.count {
                let dist = cumDist[i] - cumDist[i - 1]
                let slope = Self.slope(ele[i - 1], ele[i], over: dist)
                let speed = Self.toblerSpeed(slope)          // m/s
                let t = speed > 0 ? dist / speed : 0
                segT.append(t)
                cumT.append(cumT.last! + t)
            }
        } else {
            cumDist = [0]
        }
        cumulativeDistance = cumDist
        cumulativeTime = cumT
        segTime = segT
        totalDistance = cumDist.last ?? 0
    }

    /// Predicted seconds remaining from `distance` metres along the route to the end.
    func calculatedRemaining(fromDistance distance: CLLocationDistance) -> TimeInterval {
        guard let totalTime = cumulativeTime.last, totalTime > 0 else { return 0 }
        return max(0, totalTime - predictedTime(at: distance))
    }

    /// Predicted (grade-adjusted) seconds the model expects for the distance
    /// already covered — compared against actual elapsed time to gauge pace.
    func expectedTime(toDistance distance: CLLocationDistance) -> TimeInterval {
        predictedTime(at: distance)
    }

    private func predictedTime(at distance: CLLocationDistance) -> TimeInterval {
        guard cumulativeDistance.count > 1 else { return 0 }
        if distance <= 0 { return 0 }
        if distance >= totalDistance { return cumulativeTime.last ?? 0 }
        for i in 1..<cumulativeDistance.count where cumulativeDistance[i] >= distance {
            let seg = cumulativeDistance[i] - cumulativeDistance[i - 1]
            let t = seg > 0 ? (distance - cumulativeDistance[i - 1]) / seg : 0
            return cumulativeTime[i - 1] + t * segTime[i - 1]
        }
        return cumulativeTime.last ?? 0
    }

    private static func slope(_ a: Double?, _ b: Double?, over dist: CLLocationDistance) -> Double {
        guard let a, let b, dist > 0 else { return 0 }
        // Clamp to ±60% grade — steeper than any real trail, so residual noise
        // can't blow up the estimate.
        return max(-0.6, min(0.6, (b - a) / dist))
    }

    /// Raw Tobler (on the ±150 m smoothed profile) is too fast for how John
    /// actually walks. Calibrated Nov 2026 against MapOut's own estimates and
    /// John's recorded walks, where moving time = time at >= 1 km/h (breaks
    /// excluded, slow steep climbing counted):
    ///   MapOut  Pok Fu Lam plan  8.1 km   2h05 vs 117 min -> x1.07
    ///   MapOut  Drawn 21 Nov     8.7 km   2h55 vs 128     -> x1.36
    ///   MapOut  Murs (Luberon)   8.1 km   2h15 vs 105     -> x1.28
    ///   walk    21 Nov 2026 HK   8.6 km   169  vs 129     -> x1.31
    ///   walk    22 Nov 2026 HK   4.3 km    66  vs  56     -> x1.17
    ///   walk    5 Oct 2026       8.0 km   165  vs 131     -> x1.26
    ///   walk    21 Jun 2026      4.4 km    65  vs  53     -> x1.22
    /// Mean x1.24. Breaks are NOT included: the longer walks also stood still
    /// for 50–90 min in total. Komoot's built-in plans are slower still.
    static let paceFactor = 1.25

    /// Tobler speed in metres/second, slowed by `paceFactor`.
    private static func toblerSpeed(_ slope: Double) -> Double {
        let kmh = 6.0 * exp(-3.5 * abs(slope + 0.05)) / paceFactor
        return kmh * 1000.0 / 3600.0
    }
}
