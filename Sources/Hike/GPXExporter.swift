import Foundation
import CoreLocation

/// One recorded fix along the actual walk.
struct RecordedPoint {
    let coordinate: CLLocationCoordinate2D
    let elevation: Double?
    let time: Date
}

/// Writes the recorded track back out as a GPX file to share to another app.
enum GPXExporter {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func gpxString(track: [RecordedPoint], name: String) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Stay on Track" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(escape(name))</name>
            <trkseg>

        """
        for p in track {
            xml += "      <trkpt lat=\"\(p.coordinate.latitude)\" lon=\"\(p.coordinate.longitude)\">\n"
            if let ele = p.elevation {
                xml += "        <ele>\(String(format: "%.1f", ele))</ele>\n"
            }
            xml += "        <time>\(iso.string(from: p.time))</time>\n"
            xml += "      </trkpt>\n"
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    /// Writes the GPX to a temp file and returns its URL for sharing.
    static func write(track: [RecordedPoint], name: String) -> URL? {
        let xml = gpxString(track: track, name: name)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe).gpx")
        do {
            try xml.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
