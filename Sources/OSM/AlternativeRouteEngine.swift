import Foundation
import CoreLocation

/// A walkable graph built from OSM ways, for finding alternative routes between
/// the current hike's start and finish — offline once fetched.
struct WalkGraph {
    var coord: [Int: CLLocationCoordinate2D] = [:]
    var elevation: [Int: Double] = [:]                 // filled for avoid-steep
    var adj: [Int: [(to: Int, dist: Double)]] = [:]

    init(nodes: [Int: CLLocationCoordinate2D], ways: [[Int]]) {
        coord = nodes
        for way in ways {
            for i in 1..<way.count {
                let a = way[i - 1], b = way[i]
                guard let ca = nodes[a], let cb = nodes[b] else { continue }
                let d = CLLocation(from: ca).distance(from: CLLocation(from: cb))
                adj[a, default: []].append((b, d))
                adj[b, default: []].append((a, d))   // walking is bidirectional
            }
        }
    }

    /// Graph node nearest to a coordinate (linear scan — graphs here are small).
    func nearest(to c: CLLocationCoordinate2D) -> Int? {
        let loc = CLLocation(from: c)
        return coord.min { loc.distance(from: CLLocation(from: $0.value))
                         < loc.distance(from: CLLocation(from: $1.value)) }?.key
    }
}

enum AlternativeMode {
    case shorter        // minimise distance
    case longer         // a distinct, generally longer detour
    case avoidSteep     // minimise steepness (needs node elevations)
}

/// Finds alternative routes over a `WalkGraph` with a plain binary-heap A*.
enum RouteFinder {
    /// Edge cost for a mode. `penalise` marks edges to avoid (for the "longer"
    /// alternative, we penalise the shortest path's own edges to force a detour).
    private static func cost(_ g: WalkGraph, _ a: Int, _ b: Int, _ dist: Double,
                             mode: AlternativeMode, penalise: Set<Edge>) -> Double {
        var c = dist
        if mode == .avoidSteep, let ea = g.elevation[a], let eb = g.elevation[b] {
            let grade = abs(eb - ea) / max(1, dist)
            c *= (1 + 12 * grade)              // steep edges cost far more
        }
        if penalise.contains(Edge(a, b)) { c *= 4 }
        return c
    }

    struct Edge: Hashable { let lo: Int; let hi: Int
        init(_ a: Int, _ b: Int) { lo = min(a, b); hi = max(a, b) } }

    static func path(_ g: WalkGraph, from start: Int, to goal: Int,
                     mode: AlternativeMode, penalise: Set<Edge> = []) -> [Int]? {
        guard let goalC = g.coord[goal] else { return nil }
        func h(_ n: Int) -> Double {
            guard let c = g.coord[n] else { return 0 }
            return CLLocation(from: c).distance(from: CLLocation(from: goalC))
        }
        var gScore: [Int: Double] = [start: 0]
        var came: [Int: Int] = [:]
        var heap = Heap()
        heap.push(node: start, priority: h(start))
        var closed = Set<Int>()

        while let cur = heap.pop() {
            if cur == goal { return reconstruct(came, goal) }
            if closed.contains(cur) { continue }
            closed.insert(cur)
            let base = gScore[cur] ?? .greatestFiniteMagnitude
            for (nb, dist) in g.adj[cur] ?? [] where !closed.contains(nb) {
                let tentative = base + cost(g, cur, nb, dist, mode: mode, penalise: penalise)
                if tentative < (gScore[nb] ?? .greatestFiniteMagnitude) {
                    came[nb] = cur
                    gScore[nb] = tentative
                    heap.push(node: nb, priority: tentative + h(nb))
                }
            }
        }
        return nil
    }

    private static func reconstruct(_ came: [Int: Int], _ goal: Int) -> [Int] {
        var path = [goal], cur = goal
        while let prev = came[cur] { path.append(prev); cur = prev }
        return path.reversed()
    }

    /// A tiny binary min-heap keyed by priority.
    private struct Heap {
        private var items: [(node: Int, priority: Double)] = []
        var isEmpty: Bool { items.isEmpty }
        mutating func push(node: Int, priority: Double) {
            items.append((node, priority))
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if items[p].priority <= items[i].priority { break }
                items.swapAt(p, i); i = p
            }
        }
        mutating func pop() -> Int? {
            guard !items.isEmpty else { return nil }
            let top = items[0]
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = 2 * i + 2
                    var s = i
                    if l < items.count, items[l].priority < items[s].priority { s = l }
                    if r < items.count, items[r].priority < items[s].priority { s = r }
                    if s == i { break }
                    items.swapAt(s, i); i = s
                }
            }
            return top.node
        }
    }
}

/// Orchestrates fetching the graph and producing an alternative route as a
/// coordinate list the app can adopt. Bounded so it stays offline-friendly.
enum AlternativeRouteEngine {
    enum EngineError: Error { case noGraph, noPath, tooLarge }

    /// Node-count ceiling above which avoid-steep skips the (heavy) elevation
    /// fetch and reports back, so we never hammer the DEM API.
    private static let steepNodeCap = 1500

    static func alternative(for route: [CLLocationCoordinate2D],
                            mode: AlternativeMode) async throws -> [CLLocationCoordinate2D] {
        guard let start = route.first, let end = route.last else { throw EngineError.noPath }
        let lats = route.map(\.latitude), lons = route.map(\.longitude)
        let pad = 0.006
        let bbox = (s: lats.min()! - pad, w: lons.min()! - pad,
                    n: lats.max()! + pad, e: lons.max()! + pad)

        let (nodes, ways) = try await OverpassClient.fetchGraph(bbox: bbox)
        guard !nodes.isEmpty else { throw EngineError.noGraph }
        var graph = WalkGraph(nodes: nodes, ways: ways)

        if mode == .avoidSteep {
            guard nodes.count <= steepNodeCap else { throw EngineError.tooLarge }
            // One batched DEM fetch for all node coordinates.
            let ids = Array(nodes.keys)
            let coords = ids.map { nodes[$0]! }
            if let eles = try? await ElevationClient.fetch(coords) {
                for (i, id) in ids.enumerated() where i < eles.count { graph.elevation[id] = eles[i] }
            }
        }

        guard let s = graph.nearest(to: start), let g = graph.nearest(to: end) else {
            throw EngineError.noPath
        }

        let mainPath = RouteFinder.path(graph, from: s, to: g, mode: mode == .longer ? .shorter : mode)
        guard let main = mainPath else { throw EngineError.noPath }

        let chosen: [Int]
        if mode == .longer {
            // Penalise the shortest path's edges and re-run to get a detour.
            var pen = Set<RouteFinder.Edge>()
            for i in 1..<main.count { pen.insert(.init(main[i - 1], main[i])) }
            chosen = RouteFinder.path(graph, from: s, to: g, mode: .shorter, penalise: pen) ?? main
        } else {
            chosen = main
        }
        let coords = chosen.compactMap { graph.coord[$0] }
        guard coords.count > 1 else { throw EngineError.noPath }
        return coords
    }
}
