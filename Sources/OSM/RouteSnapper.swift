import Foundation
import CoreLocation

/// Recovers a route's true on-trail length by snapping each GPX hop onto the OSM
/// walk network and measuring along the real (curved) way geometry.
///
/// Why this exists: a GPX stores only sampled points, and the straight-line sum
/// between sparse points chords across every bend. A planned route sampled every
/// ~100 m therefore reads ~10–15% short of the trail actually walked (measured:
/// the Tour du Mont Blanc GPX sums to 150 km against its real ~170 km). The
/// slope (2D-vs-3D) component is tiny by comparison — ~1%. The shortfall is
/// almost all lost curve, so the fix is to match each hop to the OSM ways (which
/// the app already downloads at import for junctions) and measure along that
/// geometry, restoring the bends the sampling dropped.
///
/// Faithful to the route as drawn: it map-matches hop-by-hop, never a global
/// shortest path, so scenic detours and loops survive. Each hop is floored at
/// its straight-line length (a route can never end up reading *shorter* than the
/// naive sum) and capped, so a bad match — a jump onto a parallel trail, or a
/// point off the network — falls back to the raw hop instead of inventing
/// distance. Direction-independent (same physical trail either way). Pure and
/// synchronous; the import task runs it off the main actor once, then caches it.
enum RouteSnapper {
    struct Result: Equatable, Sendable {
        var distance: CLLocationDistance
        var recovered: Int     // hops whose OSM geometry we measured along
        var fellBack: Int      // hops kept raw (off-network or no bounded path)
    }

    /// A GPX point further than this from any trail node is treated as
    /// off-network (keep the raw hop). Covers GPS error + coordinate rounding.
    private static let snapTolerance: CLLocationDistance = 35

    static func correctedDistance(coords: [CLLocationCoordinate2D],
                                  nodes: [Int: CLLocationCoordinate2D],
                                  ways: [[Int]]) -> Result {
        let raw = rawDistance(coords)
        guard coords.count > 1, !nodes.isEmpty else {
            return Result(distance: raw, recovered: 0, fellBack: 0)
        }
        let graph = WalkGraph(nodes: nodes, ways: ways)
        let grid = SpatialGrid(nodes: nodes)

        var total: CLLocationDistance = 0
        var recovered = 0, fellBack = 0
        for i in 1..<coords.count {
            let a = coords[i - 1], b = coords[i]
            let straight = CLLocation(from: a).distance(from: CLLocation(from: b))
            let ma = grid.nearest(to: a), mb = grid.nearest(to: b)
            guard let (na, da) = ma, let (nb, db) = mb,
                  da <= snapTolerance, db <= snapTolerance else {
                total += straight; fellBack += 1; continue          // off-network hop
            }
            if na == nb {
                total += straight; continue                          // sub-edge hop, no curve to add
            }
            let cap = straight * 3 + 60
            if let along = shortestPath(graph, from: na, to: nb, cap: cap) {
                total += max(along, straight); recovered += 1
            } else {
                total += straight; fellBack += 1                     // no plausible on-trail path
            }
        }
        return Result(distance: total, recovered: recovered, fellBack: fellBack)
    }

    static func rawDistance(_ coords: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coords.count > 1 else { return 0 }
        var sum: CLLocationDistance = 0
        for i in 1..<coords.count {
            sum += CLLocation(from: coords[i - 1]).distance(from: CLLocation(from: coords[i]))
        }
        return sum
    }

    /// Dijkstra from `start` to `goal` over the walk graph, abandoned once the
    /// cheapest frontier exceeds `cap`. Returns the along-trail distance in
    /// metres, or nil if `goal` isn't reachable within the cap (→ raw fallback).
    private static func shortestPath(_ g: WalkGraph, from start: Int, to goal: Int,
                                     cap: CLLocationDistance) -> CLLocationDistance? {
        var best: [Int: CLLocationDistance] = [start: 0]
        var heap = MinHeap()
        heap.push(node: start, priority: 0)
        while let (node, dist) = heap.pop() {
            if node == goal { return dist }
            if dist > cap { return nil }
            if dist > (best[node] ?? .greatestFiniteMagnitude) { continue }
            for (nb, w) in g.adj[node] ?? [] {
                let nd = dist + w
                if nd < (best[nb] ?? .greatestFiniteMagnitude) {
                    best[nb] = nd
                    heap.push(node: nb, priority: nd)
                }
            }
        }
        return nil
    }

    /// Buckets node coordinates into a fixed lat/lon grid so the per-hop nearest
    /// lookup is a small local search instead of a scan over the whole network.
    private struct SpatialGrid {
        // ~0.0006° ≈ 55–66 m cells; a 3×3 block covers >90 m, well past the 35 m
        // snap tolerance, so the nearest trail node is always inside it.
        private static let cell = 0.0006
        private var buckets: [Int64: [Int]] = [:]
        private let nodes: [Int: CLLocationCoordinate2D]

        init(nodes: [Int: CLLocationCoordinate2D]) {
            self.nodes = nodes
            for (id, c) in nodes {
                buckets[Self.key(c.latitude, c.longitude), default: []].append(id)
            }
        }

        private static func key(_ lat: Double, _ lon: Double) -> Int64 {
            let x = Int64((lon / cell).rounded(.down))
            let y = Int64((lat / cell).rounded(.down))
            return (x << 32) ^ (y & 0xffff_ffff)
        }

        /// Nearest node id and its distance (metres), searching the query cell and
        /// its eight neighbours. Returns nil only if that neighbourhood is empty.
        func nearest(to c: CLLocationCoordinate2D) -> (Int, CLLocationDistance)? {
            let cx = Int64((c.longitude / Self.cell).rounded(.down))
            let cy = Int64((c.latitude / Self.cell).rounded(.down))
            let here = CLLocation(from: c)
            var bestId: Int?; var bestD = CLLocationDistance.greatestFiniteMagnitude
            for dx in -1...1 {
                for dy in -1...1 {
                    let k = ((cx + Int64(dx)) << 32) ^ ((cy + Int64(dy)) & 0xffff_ffff)
                    for id in buckets[k] ?? [] {
                        guard let nc = nodes[id] else { continue }
                        let d = here.distance(from: CLLocation(from: nc))
                        if d < bestD { bestD = d; bestId = id }
                    }
                }
            }
            return bestId.map { ($0, bestD) }
        }
    }

    /// Minimal binary min-heap of (node, priority), priority = distance so far.
    private struct MinHeap {
        private var items: [(node: Int, priority: CLLocationDistance)] = []
        mutating func push(node: Int, priority: CLLocationDistance) {
            items.append((node, priority))
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if items[p].priority <= items[i].priority { break }
                items.swapAt(p, i); i = p
            }
        }
        mutating func pop() -> (Int, CLLocationDistance)? {
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
            return (top.node, top.priority)
        }
    }
}
