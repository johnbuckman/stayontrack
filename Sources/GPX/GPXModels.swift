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
