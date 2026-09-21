import Foundation
import CoreLocation

/// A place where trails meet, with its graph degree (number of trail segments
/// incident). Degree ≥ 3 means a real decision point — the path you're on plus
/// at least one other branch.
struct Intersection {
    let coordinate: CLLocationCoordinate2D
    let degree: Int
}

/// Fetches the walkable trail network in a bounding box from Overpass and
/// derives the junction nodes (graph degree ≥ 3). Tries several mirrors with a
/// short per-mirror timeout so an overloaded/slow endpoint fails over quickly
/// instead of leaving the hike without junction warnings.
enum OverpassClient {
    enum FetchError: Error { case allEndpointsFailed }

    private static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        "https://overpass.openstreetmap.ru/api/interpreter"
    ]
    private static let perEndpointTimeout: TimeInterval = 20

    static func fetchIntersections(bbox: (s: Double, w: Double, n: Double, e: Double)) async throws -> [Intersection] {
        // Trails AND ordinary streets: when a route leaves the trail network to
        // cross a town or follow a road, we still want turn cues at the street
        // corners it passes, not only at trail junctions.
        let filter = "path|footway|track|steps|bridleway|cycleway|pedestrian|"
            + "unclassified|service|residential|living_street|road|"
            + "tertiary|tertiary_link|secondary|secondary_link|primary|primary_link"
        let query = """
        [out:json][timeout:25];
        way["highway"~"^(\(filter))$"](\(bbox.s),\(bbox.w),\(bbox.n),\(bbox.e));
        (._;>;);
        out;
        """
        let body = "data=\(query)".data(using: .utf8)!

        // Overpass mirrors 504 / time out intermittently under load, so retry
        // the whole list a few rounds with a short backoff before giving up.
        let maxRounds = 3
        for round in 0..<maxRounds {
            for endpoint in endpoints {
                guard let url = URL(string: endpoint) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = perEndpointTimeout
                do {
                    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    if let parsed = try? parse(data) { return parsed }
                } catch {
                    continue   // slow/dead mirror → try the next
                }
            }
            if round < maxRounds - 1 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // 2 s before retrying
            }
        }
        throw FetchError.allEndpointsFailed
    }

    /// Fetches the raw walkable graph (node coordinates + ways as node-id lists)
    /// in a bbox, for offline route-finding (alternative / avoid-steep routes).
    static func fetchGraph(bbox: (s: Double, w: Double, n: Double, e: Double)) async throws
        -> (nodes: [Int: CLLocationCoordinate2D], ways: [[Int]]) {
        let filter = "path|footway|track|steps|bridleway|cycleway|pedestrian|"
            + "unclassified|service|residential|living_street|road|"
            + "tertiary|tertiary_link|secondary|secondary_link|primary|primary_link"
        let query = """
        [out:json][timeout:25];
        way["highway"~"^(\(filter))$"](\(bbox.s),\(bbox.w),\(bbox.n),\(bbox.e));
        (._;>;);
        out;
        """
        let body = "data=\(query)".data(using: .utf8)!
        for round in 0..<3 {
            for endpoint in endpoints {
                guard let url = URL(string: endpoint) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = perEndpointTimeout
                do {
                    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
                        var nodes: [Int: CLLocationCoordinate2D] = [:]
                        var ways: [[Int]] = []
                        for e in payload.elements {
                            if e.type == "node", let lat = e.lat, let lon = e.lon {
                                nodes[e.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            } else if e.type == "way", let ns = e.nodes, ns.count > 1 {
                                ways.append(ns)
                            }
                        }
                        if !nodes.isEmpty { return (nodes, ways) }
                    }
                } catch { continue }
            }
            if round < 2 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        throw FetchError.allEndpointsFailed
    }

    // MARK: Parsing

    private struct Payload: Decodable {
        struct Element: Decodable {
            let type: String
            let id: Int
            let lat: Double?
            let lon: Double?
            let nodes: [Int]?
        }
        let elements: [Element]
    }

    private static func parse(_ data: Data) throws -> [Intersection] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var coordByNode: [Int: CLLocationCoordinate2D] = [:]
        for e in payload.elements where e.type == "node" {
            if let lat = e.lat, let lon = e.lon {
                coordByNode[e.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        let ways = payload.elements.compactMap { $0.type == "way" ? $0.nodes : nil }
        return deriveIntersections(nodes: coordByNode, ways: ways)
    }

    /// Junction nodes (graph degree ≥ 3) from a raw node/way graph — the same
    /// derivation `parse` uses, exposed so a single `fetchGraph` at import can
    /// feed both junction detection and route snapping without a second fetch.
    static func deriveIntersections(nodes: [Int: CLLocationCoordinate2D],
                                    ways: [[Int]]) -> [Intersection] {
        // Graph degree: interior node +2 (edge in, edge out), endpoint +1.
        var degree: [Int: Int] = [:]
        for way in ways where way.count > 1 {
            for (i, node) in way.enumerated() {
                degree[node, default: 0] += (i == 0 || i == way.count - 1) ? 1 : 2
            }
        }
        return degree.compactMap { node, deg in
            guard deg >= 3, let coord = nodes[node] else { return nil }
            return Intersection(coordinate: coord, degree: deg)
        }
    }
}
