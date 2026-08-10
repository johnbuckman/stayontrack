import Foundation

/// Produces the maneuvers to warn about. Per the design, these are **decision
/// points** — OSM trail junctions where another path meets yours — not bends in
/// the trail. Each carries which way to keep to stay on the intended path.
enum RoutePlanner {
    static func plan(travelPoints: [GPXPoint], intersections: [Intersection]) -> [Junction] {
        JunctionPlanner.osmJunctions(travelPoints: travelPoints, intersections: intersections)
    }
}
