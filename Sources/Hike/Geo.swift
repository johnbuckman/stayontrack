import Foundation
import CoreLocation

enum Geo {
    /// Initial bearing a→b in degrees (0 = north, clockwise).
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed smallest angle from bearing `from` to bearing `to`, in (-180, 180].
    /// Positive = turning right (clockwise), negative = left.
    static func turnAngle(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Cumulative distance (metres) at each point of a polyline; first is 0.
    static func cumulativeDistances(_ coords: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        var out = [CLLocationDistance](repeating: 0, count: coords.count)
        guard coords.count > 1 else { return out }
        for i in 1..<coords.count {
            out[i] = out[i - 1] + CLLocation(from: coords[i - 1]).distance(from: CLLocation(from: coords[i]))
        }
        return out
    }

    /// The coordinate on a polyline at a given cumulative distance.
    static func coordinate(at distance: CLLocationDistance,
                           coords: [CLLocationCoordinate2D],
                           cumulative: [CLLocationDistance]) -> CLLocationCoordinate2D? {
        guard coords.count > 1 else { return coords.first }
        if distance <= 0 { return coords.first }
        if distance >= cumulative.last! { return coords.last }
        for i in 1..<coords.count where cumulative[i] >= distance {
            let seg = cumulative[i] - cumulative[i - 1]
            let t = seg > 0 ? (distance - cumulative[i - 1]) / seg : 0
            return CLLocationCoordinate2D(
                latitude: coords[i - 1].latitude + (coords[i].latitude - coords[i - 1].latitude) * t,
                longitude: coords[i - 1].longitude + (coords[i].longitude - coords[i - 1].longitude) * t)
        }
        return coords.last
    }
}

/// How the route bends through a junction, as a spoken phrase.
enum TurnKind: String {
    case straight       = "straight"
    case gentleLeft     = "gentle left"
    case left           = "left"
    case hardLeft       = "hard left"
    case gentleRight    = "gentle right"
    case right          = "right"
    case hardRight      = "hard right"

    /// Classify from a signed turn angle (positive = right).
    static func classify(_ angle: Double) -> TurnKind {
        let m = abs(angle)
        if m < 20 { return .straight }
        let right = angle > 0
        switch m {
        case 20..<55:  return right ? .gentleRight : .gentleLeft
        case 55..<115: return right ? .right : .left
        default:       return right ? .hardRight : .hardLeft
        }
    }
}
