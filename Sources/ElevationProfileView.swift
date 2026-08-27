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
    /// Forecast temperature (°C) at each `profile` sample, aligned by index.
    /// Empty → no weather line drawn.
    var temperatures: [Double?] = []
    /// Predicted clock time you're at each `profile` sample, aligned by index —
    /// used to drop a temperature label on every whole hour of the walk.
    var sampleTimes: [Date?] = []

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

            // Before the hike starts (idle → progress 0) show the profile over
            // plain LINEAR distance — the whole walk at true proportions. Once
            // hiking, switch to the log-compressed "distance ahead" scale so the
            // terrain just in front stays detailed.
            let useLinear = progress <= 0
            func x(_ distance: Double) -> CGFloat {
                let dAhead = max(0, distance - progress)
                if useLinear {
                    return CGFloat(Double(size.width) * (dAhead / ahead))
                }
                return CGFloat(Double(size.width) * (log(1 + dAhead / d0) / denom))
            }

            // White text with a dark halo so numbers stay readable over both the
            // bright orange band and the map behind it.
            func drawLabel(_ text: Text, at p: CGPoint, anchor: UnitPoint) {
                let haloed = text.foregroundColor(.black)
                for dx in [-1.0, 1.0] {
                    for dy in [-1.0, 1.0] {
                        ctx.draw(haloed, at: CGPoint(x: p.x + dx, y: p.y + dy), anchor: anchor)
                    }
                }
                ctx.draw(text.foregroundColor(.white), at: p, anchor: anchor)
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
                drawLabel(Text("\(Int(km / 1000)) km").font(.system(size: 11, weight: .bold)),
                          at: CGPoint(x: kx, y: 9), anchor: .center)
                km += 1000
            }

            // Elevation numbers are shown RELATIVE to the CURRENT position, so a
            // "+20 m" label means 20 m of climb still ahead to that point (and a
            // negative number is a dip below where you're standing). Before the
            // hike starts this is the route's start elevation.
            let startElev = elevationAt(progress) ?? profile.first?.elevation ?? 0
            func rel(_ e: Double) -> Int { Int((e - startElev).rounded()) }

            // Label each PROMINENT local peak, right at the peak, with its height
            // relative to the current position. (Filters out noise and the old
            // "+0 at current height" markers that the level-crossing scheme drew.)
            if remaining.count >= 3 {
                let elevs = remaining.map(\.elevation)
                let prominence = 15.0        // metres a bump must rise to count as a peak
                let window = 3               // ± samples to measure prominence over
                var lastLabelX: CGFloat = -1000
                for i in 1..<(remaining.count - 1) {
                    guard elevs[i] >= elevs[i - 1], elevs[i] > elevs[i + 1] else { continue }
                    let lo = max(0, i - window), hi = min(elevs.count - 1, i + window)
                    let localMin = elevs[lo...hi].min() ?? elevs[i]
                    guard elevs[i] - localMin >= prominence else { continue }
                    let px = x(remaining[i].distance), py = y(elevs[i])
                    guard px - lastLabelX >= 40 else { continue }   // don't crowd labels
                    lastLabelX = px
                    var tri = Path()
                    tri.move(to: CGPoint(x: px, y: py - 2))
                    tri.addLine(to: CGPoint(x: px - 4, y: py - 9))
                    tri.addLine(to: CGPoint(x: px + 4, y: py - 9))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(.white))
                    drawLabel(Text(String(format: "%+d m", rel(elevs[i])))
                                .font(.system(size: 12, weight: .bold)),
                              at: CGPoint(x: min(max(px, 30), size.width - 30), y: py + 9),
                              anchor: .top)
                }
            }

            // Forecast temperature line over the SAME x-axis (distance → the
            // predicted clock time you're there, folded in upstream). Own scale,
            // drawn as a distinct dashed pink line with a couple of °C labels.
            if temperatures.count == profile.count, profile.count > 1 {
                func tempAt(_ d: Double) -> Double? {
                    if d <= profile.first!.distance { return temperatures.first ?? nil }
                    if d >= profile.last!.distance { return temperatures.last ?? nil }
                    for i in 1..<profile.count where profile[i].distance >= d {
                        guard let a = temperatures[i - 1], let b = temperatures[i] else { return temperatures[i] ?? temperatures[i - 1] ?? nil }
                        let seg = profile[i].distance - profile[i - 1].distance
                        let t = seg > 0 ? (d - profile[i - 1].distance) / seg : 0
                        return a + (b - a) * t
                    }
                    return temperatures.last ?? nil
                }
                let visible: [(d: Double, t: Double)] = remaining.compactMap { s in
                    tempAt(s.distance).map { (s.distance, $0) }
                }
                if visible.count > 1 {
                    let tMin = visible.map(\.t).min() ?? 0
                    let tMax = visible.map(\.t).max() ?? 1
                    let tRange = max(4, tMax - tMin)
                    // Confine the temperature line to the upper third so it reads
                    // as a separate track above the terrain.
                    func ty(_ v: Double) -> CGFloat {
                        let frac = (v - tMin) / tRange
                        return 8 + (1 - CGFloat(frac)) * (size.height * 0.33)
                    }
                    var tline = Path()
                    for (i, p) in visible.enumerated() {
                        let pt = CGPoint(x: x(p.d), y: ty(p.t))
                        if i == 0 { tline.move(to: pt) } else { tline.addLine(to: pt) }
                    }
                    ctx.stroke(tline, with: .color(Color(red: 1, green: 0.4, blue: 0.5)),
                               style: StrokeStyle(lineWidth: 2, dash: [5, 3]))

                    // A temperature label on every whole hour of the walk. The
                    // predicted clock time is interpolated between samples; at
                    // each hour boundary we place a dot + the temperature there.
                    if sampleTimes.count == profile.count {
                        func timeAt(_ d: Double) -> Date? {
                            if d <= profile.first!.distance { return sampleTimes.first ?? nil }
                            if d >= profile.last!.distance { return sampleTimes.last ?? nil }
                            for i in 1..<profile.count where profile[i].distance >= d {
                                guard let a = sampleTimes[i - 1], let b = sampleTimes[i] else { return sampleTimes[i] ?? sampleTimes[i - 1] ?? nil }
                                let seg = profile[i].distance - profile[i - 1].distance
                                let t = seg > 0 ? (d - profile[i - 1].distance) / seg : 0
                                return Date(timeIntervalSince1970: a.timeIntervalSince1970 + (b.timeIntervalSince1970 - a.timeIntervalSince1970) * t)
                            }
                            return sampleTimes.last ?? nil
                        }
                        var lastLabelX: CGFloat = -1000
                        for i in 1..<visible.count {
                            guard let t0 = timeAt(visible[i - 1].d),
                                  let t1 = timeAt(visible[i].d), t1 > t0 else { continue }
                            let s0 = t0.timeIntervalSince1970, s1 = t1.timeIntervalSince1970
                            var boundary = (s0 / 3600).rounded(.up) * 3600
                            while boundary <= s1 {
                                let f = (boundary - s0) / (s1 - s0)
                                let d = visible[i - 1].d + f * (visible[i].d - visible[i - 1].d)
                                if let temp = tempAt(d) {
                                    let px = x(d), py = ty(temp)
                                    if px - lastLabelX >= 34 {
                                        lastLabelX = px
                                        ctx.fill(Path(ellipseIn: CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)),
                                                 with: .color(Color(red: 1, green: 0.4, blue: 0.5)))
                                        drawLabel(Text("\(Int(temp.rounded()))°").font(.system(size: 14, weight: .bold)),
                                                  at: CGPoint(x: px, y: py - 11), anchor: .center)
                                    }
                                }
                                boundary += 3600
                            }
                        }
                    } else if let f = visible.first {
                        // No timing info → just label the starting temperature.
                        drawLabel(Text("\(Int(f.t.rounded()))°").font(.system(size: 11, weight: .bold)),
                                  at: CGPoint(x: x(f.d) + 12, y: ty(f.t) - 8), anchor: .center)
                    }
                }
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
