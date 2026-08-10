import Foundation
import CoreLocation

/// A dot placed along the route, labelled with the actual distance in km.
struct DistanceMarker: Identifiable, Equatable {
    let id: Int                       // 1, 2, 3 ... in travel order
    let coordinate: CLLocationCoordinate2D
    let distanceMeters: CLLocationDistance   // distance from the start of travel
    /// Real distance label in km, e.g. "0.5", "1", "1.5", "2".
    var label: String {
        let km = distanceMeters / 1000.0
        return km == km.rounded() ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    static func == (l: DistanceMarker, r: DistanceMarker) -> Bool {
        l.id == r.id && l.distanceMeters == r.distanceMeters &&
        l.coordinate.latitude == r.coordinate.latitude &&
        l.coordinate.longitude == r.coordinate.longitude
    }
}

enum RouteGeometry {
    static let markerSpacing: CLLocationDistance = 1000   // metres (every 1 km)

    /// Places a marker every `spacing` metres along the route.
    /// When `reversed` is true the route is walked start<-finish, so the
    /// markers renumber from the other end (the "Reverse" toggle).
    static func markers(for route: GPXRoute,
                        reversed: Bool,
                        spacing: CLLocationDistance = markerSpacing) -> [DistanceMarker] {
        var coords = route.coordinates
        if reversed { coords.reverse() }
        guard coords.count > 1 else { return [] }

        var markers: [DistanceMarker] = []
        var traveled: CLLocationDistance = 0
        var nextAt: CLLocationDistance = spacing
        var index = 1

        for i in 1..<coords.count {
            let a = coords[i - 1]
            let b = coords[i]
            let segLen = CLLocation(from: a).distance(from: CLLocation(from: b))
            guard segLen > 0 else { continue }

            // Drop as many markers as fall inside this segment.
            while nextAt <= traveled + segLen {
                let t = (nextAt - traveled) / segLen          // 0...1 along segment
                let coord = interpolate(a, b, t)
                markers.append(DistanceMarker(id: index,
                                              coordinate: coord,
                                              distanceMeters: nextAt))
                index += 1
                nextAt += spacing
            }
            traveled += segLen
        }
        return markers
    }

    /// Linear interpolation between two coordinates (fine at trail scale).
    private static func interpolate(_ a: CLLocationCoordinate2D,
                                    _ b: CLLocationCoordinate2D,
                                    _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}
