import CoreLocation

/// A single point along a route/track. Elevation is optional (used later only
/// for the grade-adjusted "Calculated ETA", never displayed).
struct GPXPoint: Equatable {
    var coordinate: CLLocationCoordinate2D
    var elevation: Double?   // metres, if present in the GPX

    static func == (lhs: GPXPoint, rhs: GPXPoint) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.elevation == rhs.elevation
    }
}

/// A parsed planned hike. Points are in file order (start -> finish).
struct GPXRoute: Equatable {
    var name: String?
    var points: [GPXPoint]
    /// Turn-network results Stay on Track saved into its own copy of the file
    /// (nil for a GPX from another app). See `StoredTrail`.
    var trail: StoredTrail? = nil

    var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }
    var hasElevation: Bool { points.contains { $0.elevation != nil } }

    /// Total length in metres, measured along the ordered points.
    var totalDistance: CLLocationDistance {
        guard points.count > 1 else { return 0 }
        var sum: CLLocationDistance = 0
        for i in 1..<points.count {
            sum += CLLocation(from: points[i - 1].coordinate)
                .distance(from: CLLocation(from: points[i].coordinate))
        }
        return sum
    }
}

extension CLLocation {
    convenience init(from c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }
}

/// What Stay on Track writes into the `<extensions>` of its saved GPX copy so a
/// route never needs its turns recalculated: the OSM junction nodes near the
/// route (direction-independent), whether every piece of the route was covered,
/// and the OSM-snapped trail length together with the route key it was measured
/// for (a length only applies to exactly those coordinates).
struct StoredTrail: Equatable {
    var intersections: [Intersection]
    var complete: Bool
    var length: Double?
    var lengthKey: String?

    static func == (a: StoredTrail, b: StoredTrail) -> Bool {
        a.complete == b.complete && a.length == b.length && a.lengthKey == b.lengthKey
            && a.intersections.count == b.intersections.count
            && zip(a.intersections, b.intersections).allSatisfy {
                $0.coordinate.latitude == $1.coordinate.latitude
                    && $0.coordinate.longitude == $1.coordinate.longitude && $0.degree == $1.degree
            }
    }
}
