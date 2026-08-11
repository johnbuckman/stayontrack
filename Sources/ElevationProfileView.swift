import SwiftUI

/// One point of the route's elevation profile.
struct ElevationSample: Equatable {
    let distance: Double     // cumulative metres from start
    let elevation: Double    // metres
}

/// The elevation of the trail *ahead*, drawn as an area chart anchored at the
/// bottom-left. The x-axis is log-compressed on distance-ahead so nearby terrain
/// is wide and detailed while far terrain compresses — small climbs just ahead
/// stay visible even on a long hike (which a linear profile flattens away).
struct ElevationProfileView: View {
    let profile: [ElevationSample]
    let progress: Double     // current distance along the route
    let total: Double

    /// Distance scale: below ~this many metres the mapping is near-linear (most detail).
    private let d0: Double = 150

    var body: some View {
        Canvas { ctx, size in
            // Elevation at any distance, so the chart can start exactly at the
            // current position (x = 0) instead of the next sample point (which
            // would draw a diagonal from the bottom-left corner).
            func elevationAt(_ d: Double) -> Double? {
                guard let first = profile.first, let last = profile.last else { return nil }
                if d <= first.distance { return first.elevation }
                if d >= last.distance { return last.elevation }
                for i in 1..<profile.count where profile[i].distance >= d {
                    let a = profile[i - 1], b = profile[i]
                    let seg = b.distance - a.distance
                    let t = seg > 0 ? (d - a.distance) / seg : 0
                    return a.elevation + (b.elevation - a.elevation) * t
                }
                return last.elevation
            }
            var remaining = profile.filter { $0.distance > progress }
            if let e0 = elevationAt(progress) {
                remaining.insert(ElevationSample(distance: progress, elevation: e0), at: 0)
            }
            guard remaining.count > 1 else { return }
            let ahead = max(1, total - progress)
            let denom = log(1 + ahead / d0)

            func x(_ distance: Double) -> CGFloat {
                let dAhead = max(0, distance - progress)
                return CGFloat(Double(size.width) * (log(1 + dAhead / d0) / denom))
            }
            let elevs = remaining.map(\.elevation)
            let eMin = elevs.min() ?? 0
            let eMax = elevs.max() ?? 1
            let range = max(8, eMax - eMin)   // floor so a flat hike isn't a razor line
            let topPad: CGFloat = 10
            func y(_ e: Double) -> CGFloat {
                let t = (e - eMin) / range
                return size.height - CGFloat(t) * (size.height - topPad)
            }

            var line = Path()
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (i, p) in remaining.enumerated() {
                let pt = CGPoint(x: x(p.distance), y: y(p.elevation))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                area.addLine(to: pt)
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()

            let elevColor = Color.orange
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [elevColor.opacity(0.5), elevColor.opacity(0.08)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(elevColor), lineWidth: 2.5)

            // Kilometre markings (absolute route distance, matching the map's km
            // markers) — vertical lines so distance is readable despite the
            // non-linear x-axis.
            var km = (floor(progress / 1000) + 1) * 1000
            while km <= total {
                let kx = x(km)
                var vline = Path()
                vline.move(to: CGPoint(x: kx, y: 14))
                vline.addLine(to: CGPoint(x: kx, y: size.height))
                ctx.stroke(vline, with: .color(.black.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text("\(Int(km / 1000)) km")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white),
                         at: CGPoint(x: kx, y: 8), anchor: .center)
                km += 1000
            }

            // Elevation is shown RELATIVE to the hike's starting point.
            let startElev = profile.first?.elevation ?? 0
            func rel(_ e: Double) -> Int { Int((e - startElev).rounded()) }

            // At every 100 m of relative elevation change, just the number on
            // the line (no tick mark).
            for i in 1..<remaining.count {
                let a = remaining[i - 1], b = remaining[i]
                let ra = Double(rel(a.elevation)), rb = Double(rel(b.elevation))
                let lo = min(ra, rb), hi = max(ra, rb)
                var level = (floor(lo / 100) + 1) * 100
                while level <= hi {
                    let span = rb - ra
                    let t = span != 0 ? (level - ra) / span : 0
                    let cx = x(a.distance) + CGFloat(t) * (x(b.distance) - x(a.distance))
                    let cy = y(a.elevation) + CGFloat(t) * (y(b.elevation) - y(a.elevation))
                    ctx.draw(Text(String(format: "%+d", Int(level)))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white),
                             at: CGPoint(x: cx, y: cy - 3), anchor: .bottom)
                    level += 100
                }
            }

            // Highest point of the whole hike — a small mark plus its number,
            // placed below the point so it's never clipped at the top.
            if let peak = profile.max(by: { $0.elevation < $1.elevation }),
               peak.distance >= progress - 5 {
                let px = x(peak.distance), py = y(peak.elevation)
                var tri = Path()
                tri.move(to: CGPoint(x: px, y: py - 2))
                tri.addLine(to: CGPoint(x: px - 4, y: py - 9))
                tri.addLine(to: CGPoint(x: px + 4, y: py - 9))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(.white))
                ctx.draw(Text(String(format: "%+d m", rel(peak.elevation)))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white),
                         at: CGPoint(x: min(max(px, 30), size.width - 30), y: py + 9),
                         anchor: .top)
            }

            // "You are here" marker at the left edge.
            if let first = remaining.first {
                let py = y(first.elevation)
                ctx.fill(Path(ellipseIn: CGRect(x: -4, y: py - 4, width: 8, height: 8)),
                         with: .color(.white))
            }
        }
    }
}
