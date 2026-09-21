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
        // Smooth the elevation profile first — raw (esp. DEM-sampled) elevation
        // is noisy, and Tobler's exponential slope penalty turns that noise into
        // absurd time estimates. Slope is then clamped to a sane range.
        let ele = Self.smoothedElevations(travelPoints.map(\.elevation))
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

    /// Moving average (±2 points) over the available elevations.
    private static func smoothedElevations(_ raw: [Double?]) -> [Double?] {
        let n = raw.count
        var out = [Double?](repeating: nil, count: n)
        let r = 2
        for i in 0..<n {
            var sum = 0.0, count = 0
            for j in max(0, i - r)...min(n - 1, i + r) {
                if let e = raw[j] { sum += e; count += 1 }
            }
            out[i] = count > 0 ? sum / Double(count) : nil
        }
        return out
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

    /// Tobler speed in metres/second.
    private static func toblerSpeed(_ slope: Double) -> Double {
        let kmh = 6.0 * exp(-3.5 * abs(slope + 0.05))
        return kmh * 1000.0 / 3600.0
    }
}
