import Foundation
import CoreLocation

/// A decision point on the planned route: where along it (metres from start in
/// travel order), which way the route turns, and how many trails meet there.
struct Junction {
    let routeDistance: CLLocationDistance
    let coordinate: CLLocationCoordinate2D
    let turn: TurnKind
    let optionCount: Int
    /// Signed turn angle in degrees (positive = right) — drives keep-direction.
    let angle: Double
    /// Absolute compass bearing (deg from north) the route LEAVES the junction —
    /// this is the way the hiker should go, for the north-up map arrow.
    var outBearing: Double = 0
    /// true = an OSM trail junction; false = a bend in the route itself.
    var isTrailJunction: Bool = false

    /// Coarse direction to stay on the intended path: "left", "right", "straight".
    var keepDirection: String {
        if abs(angle) < 20 { return "straight" }
        return angle > 0 ? "right" : "left"
    }

    /// Short instruction — used for speech, the HUD, and the notification.
    var instruction: String {
        switch keepDirection {
        case "left":  return "Left"
        case "right": return "Right"
        default:      return "Straight"
        }
    }

    /// Minimal spoken cue: just the instruction.
    var spoken: String { instruction }
}

/// Matches OSM intersections onto the planned route (in travel order) and works
/// out the turn instruction from the route's own geometry at each one.
enum JunctionPlanner {
    // Relaxed: the GPX is never exactly on the OSM trail (GPS error), so allow
    // a wider match band (validated at 40 m against real junctions).
    static let matchTolerance: CLLocationDistance = 40   // node must be this close to the route
    static let lookaround: CLLocationDistance = 25       // bearing sample distance either side
    static let mergeWithin: CLLocationDistance = 30      // collapse near-duplicate junctions

    static func osmJunctions(travelPoints: [GPXPoint], intersections: [Intersection]) -> [Junction] {
        let coords = travelPoints.map(\.coordinate)
        guard coords.count > 1 else { return [] }
        let cumulative = Geo.cumulativeDistances(coords)
        let total = cumulative.last ?? 0

        var found: [Junction] = []
        for node in intersections {
            guard let hit = nearestOnRoute(node.coordinate, coords: coords, cumulative: cumulative)
            else { continue }
            if hit.distance > matchTolerance { continue }
            // Ignore the very start/end — you're not deciding there.
            if hit.routeDistance < 15 || hit.routeDistance > total - 15 { continue }

            guard
                let before = Geo.coordinate(at: hit.routeDistance - lookaround, coords: coords, cumulative: cumulative),
                let here = Geo.coordinate(at: hit.routeDistance, coords: coords, cumulative: cumulative),
                let after = Geo.coordinate(at: hit.routeDistance + lookaround, coords: coords, cumulative: cumulative)
            else { continue }

            let outBearing = Geo.bearing(here, after)
            let angle = Geo.turnAngle(from: Geo.bearing(before, here), to: outBearing)
            found.append(Junction(routeDistance: hit.routeDistance,
                                  coordinate: node.coordinate,
                                  turn: TurnKind.classify(angle),
                                  optionCount: node.degree,
                                  angle: angle,
                                  outBearing: outBearing,
                                  isTrailJunction: true))
        }

        return merge(found.sorted { $0.routeDistance < $1.routeDistance })
    }

    private static func merge(_ sorted: [Junction]) -> [Junction] {
        var out: [Junction] = []
        for j in sorted {
            if let last = out.last, j.routeDistance - last.routeDistance < mergeWithin {
                // Keep the busier junction at the shared spot.
                if j.optionCount > last.optionCount { out[out.count - 1] = j }
            } else {
                out.append(j)
            }
        }
        return out
    }

    private static func nearestOnRoute(_ p: CLLocationCoordinate2D,
                                       coords: [CLLocationCoordinate2D],
                                       cumulative: [CLLocationDistance])
    -> (distance: CLLocationDistance, routeDistance: CLLocationDistance)? {
        guard coords.count > 1 else { return nil }
        var best = CLLocationDistance.greatestFiniteMagnitude
        var bestDist: CLLocationDistance = 0
        for i in 0..<(coords.count - 1) {
            let (d, t) = PolylineTracker.distanceToSegment(p, coords[i], coords[i + 1])
            if d < best {
                best = d
                let segLen = cumulative[i + 1] - cumulative[i]
                bestDist = cumulative[i] + t * segLen
            }
        }
        return (best, bestDist)
    }
}
