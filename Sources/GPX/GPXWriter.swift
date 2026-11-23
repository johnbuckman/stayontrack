import Foundation

/// Writes a planned route back out as GPX, carrying what Stay on Track worked
/// out at import so it never has to be recalculated: every point's elevation
/// (including elevation filled in from the DEM) and, in `<extensions>`, the
/// turn network (`StoredTrail`). Other apps ignore the extension.
///
/// Used for the app's own saved copy of the last route (`last-hike.gpx`), which
/// is what is reopened on the next launch.
enum GPXWriter {
    static let namespace = "https://johnbuckman.github.io/stayontrack/gpx/1"

    static func gpxString(route: GPXRoute) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Stay on Track" xmlns="http://www.topografix.com/GPX/1/1" xmlns:sot="\(namespace)">
          <trk>

        """
        if let name = route.name { xml += "    <name>\(escape(name))</name>\n" }
        xml += "    <trkseg>\n"
        for p in route.points {
            // Full precision: re-reading must give back the exact same doubles,
            // or the route key (and so the stored length) would no longer match.
            let lat = "\(p.coordinate.latitude)", lon = "\(p.coordinate.longitude)"
            if let ele = p.elevation {
                xml += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\"><ele>\(String(format: "%.1f", ele))</ele></trkpt>\n"
            } else {
                xml += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\"/>\n"
            }
        }
        xml += "    </trkseg>\n  </trk>\n"
        if let t = route.trail {
            var attrs = "complete=\"\(t.complete)\""
            if let len = t.length, let key = t.lengthKey {
                attrs += " length=\"\(len)\" lengthKey=\"\(key)\""
            }
            xml += "  <extensions>\n    <sot:trail \(attrs)>\n"
            for i in t.intersections {
                xml += "      <sot:junction lat=\"\(i.coordinate.latitude)\""
                    + " lon=\"\(i.coordinate.longitude)\" degree=\"\(i.degree)\"/>\n"
            }
            xml += "    </sot:trail>\n  </extensions>\n"
        }
        xml += "</gpx>\n"
        return xml
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
