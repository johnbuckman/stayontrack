import Foundation
import CoreLocation

/// Minimal, dependency-free GPX reader built on Foundation's XMLParser.
///
/// Handles the three ways a hike shows up in a GPX file:
///   - <trk>/<trkseg>/<trkpt>  (a recorded or planned track)
///   - <rte>/<rtept>           (a route)
///   - <wpt>                    (loose waypoints, fallback only)
/// Track points win over route points win over waypoints.
enum GPXParser {
    enum ParseError: LocalizedError {
        case noPoints
        case malformed
        var errorDescription: String? {
            switch self {
            case .noPoints:  return "This GPX file has no track, route, or waypoints."
            case .malformed: return "This file could not be read as GPX."
            }
        }
    }

    static func parse(data: Data) throws -> GPXRoute {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.malformed }

        let points: [GPXPoint]
        if !delegate.trkpts.isEmpty      { points = delegate.trkpts }
        else if !delegate.rtepts.isEmpty { points = delegate.rtepts }
        else                             { points = delegate.wpts }

        guard points.count >= 2 else { throw ParseError.noPoints }
        return GPXRoute(name: delegate.trackName ?? delegate.metadataName, points: points)
    }

    static func parse(url: URL) throws -> GPXRoute {
        // Handle security-scoped URLs handed over by the share sheet / Files.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    // MARK: - XMLParser delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var trkpts: [GPXPoint] = []
        var rtepts: [GPXPoint] = []
        var wpts: [GPXPoint] = []

        var metadataName: String?
        var trackName: String?

        private var pendingCoord: CLLocationCoordinate2D?
        private var pendingEle: Double?
        private var currentBucket: Bucket?
        private var text = ""
        private var stack: [String] = []

        private enum Bucket { case trk, rte, wpt }

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attr: [String: String]) {
            switch element {
            case "trkpt": currentBucket = .trk; startPoint(attr)
            case "rtept": currentBucket = .rte; startPoint(attr)
            case "wpt":   currentBucket = .wpt; startPoint(attr)
            case "ele", "name": text = ""
            default: break
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            switch element {
            case "ele":
                pendingEle = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "name":
                // Take the route title from <metadata>/<trk>/<rte>, never from
                // <author>/<wpt>/<rtept>. Track name wins over metadata name.
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    if parent == "trk" || parent == "rte" { trackName = value }
                    else if parent == "metadata" { metadataName = value }
                }
            case "trkpt", "rtept", "wpt":
                finishPoint()
            default:
                break
            }
            if stack.last == element { stack.removeLast() }
        }

        private func startPoint(_ attr: [String: String]) {
            pendingEle = nil
            if let latS = attr["lat"], let lonS = attr["lon"],
               let lat = Double(latS), let lon = Double(lonS) {
                pendingCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            } else {
                pendingCoord = nil
            }
        }

        private func finishPoint() {
            defer { pendingCoord = nil; pendingEle = nil; currentBucket = nil }
            guard let coord = pendingCoord else { return }
            let point = GPXPoint(coordinate: coord, elevation: pendingEle)
            switch currentBucket {
            case .trk: trkpts.append(point)
            case .rte: rtepts.append(point)
            case .wpt: wpts.append(point)
            case .none: break
            }
        }
    }
}
