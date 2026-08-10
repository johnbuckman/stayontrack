import Foundation
import UIKit
import CoreLocation

/// Deep links to third-party navigation apps for driving to the trailhead.
/// iOS has no universal "navigate with any app" API, so each app is reached by
/// its own URL scheme; Tesla and others are reached via the share sheet instead.
enum NavApps {
    /// Apple Maps driving directions to the coordinate (always available).
    static func appleMaps(_ c: CLLocationCoordinate2D) -> URL {
        URL(string: "http://maps.apple.com/?daddr=\(c.latitude),\(c.longitude)&dirflg=d")!
    }

    /// Google Maps app (nil-safe; shown only if installed).
    static func googleMaps(_ c: CLLocationCoordinate2D) -> URL? {
        URL(string: "comgooglemaps://?daddr=\(c.latitude),\(c.longitude)&directionsmode=driving")
    }

    /// Waze app (nil-safe; shown only if installed).
    static func waze(_ c: CLLocationCoordinate2D) -> URL? {
        URL(string: "waze://?ll=\(c.latitude),\(c.longitude)&navigate=yes")
    }

    /// A shareable maps link for the system share sheet — Tesla's app (and
    /// others that register for locations) picks this up.
    static func shareURL(_ c: CLLocationCoordinate2D) -> URL {
        URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=Trailhead")!
    }

    static func canOpen(_ url: URL) -> Bool {
        UIApplication.shared.canOpenURL(url)
    }
}
