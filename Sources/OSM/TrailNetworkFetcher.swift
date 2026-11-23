import Foundation
import CoreLocation

/// The walkable OSM network near a route: node coordinates and ways (as node-id
/// lists, keyed by way id so pieces fetched separately merge without duplicates).
struct TrailGraph {
    var nodes: [Int: CLLocationCoordinate2D] = [:]
    var ways: [Int: [Int]] = [:]

    mutating func merge(_ other: TrailGraph) {
        nodes.merge(other.nodes) { a, _ in a }
        ways.merge(other.ways) { a, _ in a }
    }

    var wayLists: [[Int]] { Array(ways.values) }
}

/// Downloads the trail network along a route in small pieces instead of one
/// big rectangle.
///
/// Why: the old single bounding-box query asked for every road and path in the
/// whole rectangle around the hike. Over a city (Pok Fu Lam, Hong Kong, Nov 2026)
/// that is a 5 MB answer taking 35 s on the fastest public Overpass server, close
/// to the 45 s timeout, and the public servers are often overloaded or down
/// outright — all four failed on 23 Nov 2026. So:
///   - the route is cut into ~600 m pieces, each a small box padded 120 m, so
///     each request is small and quick, and turns can be shown as pieces arrive;
///   - each piece tries Overpass with a short timeout, then the main
///     OpenStreetMap API (`/api/0.6/map`), which answered the same kind of
///     request in under 2 s when Overpass was down. After two Overpass failures
///     the rest of the pieces go straight to the OSM API.
///
/// A node's junction degree is complete once the piece containing it is in,
/// because a box returns every way that touches it (whole ways, all nodes).
enum TrailNetworkFetcher {
    struct BBox { let s, w, n, e: Double }

    enum FetchError: Error { case pieceFailed, tooLarge }

    /// The highway types that make up the walking network (trails AND streets,
    /// so a route through a town still gets turn cues at corners).
    static let highwayTypes: Set<String> = [
        "path", "footway", "track", "steps", "bridleway", "cycleway", "pedestrian",
        "unclassified", "service", "residential", "living_street", "road",
        "tertiary", "tertiary_link", "secondary", "secondary_link", "primary", "primary_link"
    ]

    static let pieceLength: CLLocationDistance = 600
    static let pad: CLLocationDistance = 120
    private static let maxConcurrent = 3

    /// The route cut into consecutive pieces of about `pieceLength`, each as a
    /// padded box. Adjacent pieces share their boundary point, so nothing between
    /// them is missed.
    static func pieces(for coords: [CLLocationCoordinate2D]) -> [BBox] {
        guard !coords.isEmpty else { return [] }
        var out: [BBox] = []
        var start = 0
        var run: CLLocationDistance = 0
        for i in 1..<max(coords.count, 1) {
            run += CLLocation(from: coords[i - 1]).distance(from: CLLocation(from: coords[i]))
            if run >= pieceLength || i == coords.count - 1 {
                out.append(box(coords[start...i]))
                start = i
                run = 0
            }
        }
        if out.isEmpty { out.append(box(coords[0...])) }
        return out
    }

    private static func box(_ slice: ArraySlice<CLLocationCoordinate2D>) -> BBox {
        let lats = slice.map(\.latitude), lons = slice.map(\.longitude)
        let midLat = (lats.min()! + lats.max()!) / 2
        let dLat = pad / 111_320
        let dLon = pad / (111_320 * max(0.2, cos(midLat * .pi / 180)))
        return BBox(s: lats.min()! - dLat, w: lons.min()! - dLon,
                    n: lats.max()! + dLat, e: lons.max()! + dLon)
    }

    /// Fetches every piece (up to three at once, in route order) and calls
    /// `onPiece` on the main actor after each one with the merged graph so far
    /// and the count done. Throws only after every piece has been tried; the
    /// graph passed to the last `onPiece` call then holds whatever did arrive.
    static func fetch(coords: [CLLocationCoordinate2D],
                      onPiece: @escaping @MainActor (TrailGraph, _ done: Int, _ total: Int) -> Void)
    async throws -> TrailGraph {
        let boxes = pieces(for: coords)
        let picker = SourcePicker()
        var merged = TrailGraph()
        var done = 0, failed = 0
        await onPiece(merged, 0, boxes.count)

        try await withThrowingTaskGroup(of: TrailGraph?.self) { group in
            var next = 0
            func launch() {
                guard next < boxes.count else { return }
                let b = boxes[next]
                next += 1
                group.addTask { try? await fetchPiece(b, picker: picker) }
            }
            for _ in 0..<min(maxConcurrent, boxes.count) { launch() }
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let g = result { merged.merge(g) } else { failed += 1 }
                done += 1
                await onPiece(merged, done, boxes.count)
                launch()
            }
        }
        if failed > 0 { throw FetchError.pieceFailed }
        return merged
    }

    // MARK: One piece

    private static func fetchPiece(_ b: BBox, picker: SourcePicker) async throws -> TrailGraph {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if let endpoint = await picker.overpassEndpoint() {
                if let g = try? await overpass(b, endpoint: endpoint) { return g }
                await picker.overpassFailed()
            }
            if let g = try? await osmAPI(b, depth: 0) { return g }
            try await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
        }
        throw FetchError.pieceFailed
    }

    /// Shares the "is Overpass worth trying" verdict across all pieces of one fetch.
    private actor SourcePicker {
        private static let endpoints = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter"
        ]
        private var failures = 0
        private var turn = 0
        func overpassEndpoint() -> String? {
            guard failures < 2 else { return nil }
            defer { turn += 1 }
            return Self.endpoints[turn % Self.endpoints.count]
        }
        func overpassFailed() { failures += 1 }
    }

    private static func overpass(_ b: BBox, endpoint: String) async throws -> TrailGraph {
        let filter = highwayTypes.sorted().joined(separator: "|")
        let query = """
        [out:json][timeout:10];
        way["highway"~"^(\(filter))$"](\(b.s),\(b.w),\(b.n),\(b.e));
        (._;>;);
        out skel;
        """
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Short: a healthy server answers a piece in a few seconds, and a dead
        // one should hand over to the OSM API quickly.
        request.timeoutInterval = 12
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        let (data, response) = try await URLSession.shared.upload(for: request, from: Data(body.utf8))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.pieceFailed }

        struct Payload: Decodable {
            struct Element: Decodable {
                let type: String; let id: Int
                let lat: Double?; let lon: Double?; let nodes: [Int]?
            }
            let elements: [Element]
            let remark: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        // A query that overran answers 200 with a "runtime error" remark and no
        // elements — a failure, not an empty area.
        if payload.remark?.contains("error") == true { throw FetchError.pieceFailed }
        var g = TrailGraph()
        for e in payload.elements {
            if e.type == "node", let lat = e.lat, let lon = e.lon {
                g.nodes[e.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            } else if e.type == "way", let ns = e.nodes, ns.count > 1 {
                g.ways[e.id] = ns
            }
        }
        return g
    }

    /// The main OSM API returns everything in the box (buildings too), as XML;
    /// keep only walkable ways and the nodes they use. It refuses boxes holding
    /// more than 50,000 nodes (HTTP 400): split the box and try the halves.
    private static func osmAPI(_ b: BBox, depth: Int) async throws -> TrailGraph {
        let s = String(format: "%.6f,%.6f,%.6f,%.6f", b.w, b.s, b.e, b.n)
        var request = URLRequest(url: URL(string: "https://api.openstreetmap.org/api/0.6/map?bbox=\(s)")!)
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400, depth < 3 {
            let midLat = (b.s + b.n) / 2, midLon = (b.w + b.e) / 2
            let halves = (b.n - b.s) > (b.e - b.w)
                ? [BBox(s: b.s, w: b.w, n: midLat, e: b.e), BBox(s: midLat, w: b.w, n: b.n, e: b.e)]
                : [BBox(s: b.s, w: b.w, n: b.n, e: midLon), BBox(s: b.s, w: midLon, n: b.n, e: b.e)]
            var g = TrailGraph()
            for h in halves { g.merge(try await osmAPI(h, depth: depth + 1)) }
            return g
        }
        guard status == 200 else { throw FetchError.pieceFailed }
        return try OSMXMLGraphParser.parse(data, highwayTypes: highwayTypes)
    }
}

/// Reads an OSM API `/map` XML answer into a walkable `TrailGraph`.
final class OSMXMLGraphParser: NSObject, XMLParserDelegate {
    private var nodes: [Int: CLLocationCoordinate2D] = [:]
    private var ways: [Int: [Int]] = [:]
    private var wayID: Int?
    private var wayNodes: [Int] = []
    private var wayHighway: String?
    private let highwayTypes: Set<String>

    private init(highwayTypes: Set<String>) { self.highwayTypes = highwayTypes }

    static func parse(_ data: Data, highwayTypes: Set<String>) throws -> TrailGraph {
        let d = OSMXMLGraphParser(highwayTypes: highwayTypes)
        let parser = XMLParser(data: data)
        parser.delegate = d
        guard parser.parse() else { throw TrailNetworkFetcher.FetchError.pieceFailed }
        // Keep only the nodes the walkable ways use (the box also holds buildings).
        let used = Set(d.ways.values.joined())
        var g = TrailGraph()
        g.ways = d.ways
        for id in used { if let c = d.nodes[id] { g.nodes[id] = c } }
        return g
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        switch element {
        case "node":
            if let id = a["id"].flatMap(Int.init), let lat = a["lat"].flatMap(Double.init),
               let lon = a["lon"].flatMap(Double.init) {
                nodes[id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        case "way":
            wayID = a["id"].flatMap(Int.init); wayNodes = []; wayHighway = nil
        case "nd":
            if wayID != nil, let ref = a["ref"].flatMap(Int.init) { wayNodes.append(ref) }
        case "tag":
            if wayID != nil, a["k"] == "highway" { wayHighway = a["v"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard element == "way", let id = wayID else { return }
        if let h = wayHighway, highwayTypes.contains(h), wayNodes.count > 1 { ways[id] = wayNodes }
        wayID = nil
    }
}
