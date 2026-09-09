import SwiftUI
import MapKit

/// MKMapView wrapped for SwiftUI so it can host the OSM tile overlay (the new
/// SwiftUI Map can't). Draws the OSM basemap, the planned route, the numbered
/// 0.5 km markers, the faint breadcrumb of where you've actually walked, and a
/// draggable walker dot (simulate mode: drag it to "walk").
struct RouteMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let markers: [DistanceMarker]
    var junctions: [Junction] = []
    var restaurants: [TrailRestaurant] = []
    var toilets: [TrailToilet] = []
    var walker: CLLocationCoordinate2D?
    var breadcrumb: [CLLocationCoordinate2D] = []
    var simulating: Bool = false
    var onWalk: ((CLLocationCoordinate2D) -> Void)?
    /// Keep the walker centred (real walk). Zoom is always left as the user set it.
    var autoFollow: Bool = false
    var following: Bool = true
    var onUserPan: (() -> Void)?
    /// Per-point elevations (metres) aligned to `coordinates`, for grade-based
    /// line width. Empty → the route draws at a single uniform width.
    var elevations: [Double?] = []
    /// Distance walked so far, for the "beyond the next 1 km fades back" effect.
    var progressDistance: Double = 0
    /// Device compass heading (true north degrees) → the on-map compass needle.
    var walkerHeading: Double?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = true    // two-finger rotate; arrows are heading-compensated below
        map.isPitchEnabled = false
        map.showsCompass = true       // built-in compass appears when rotated; tap it to reset north
        let overlay = OSMTileOverlay()
        map.addOverlay(overlay, level: .aboveLabels)

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)

        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onWalk = onWalk
        context.coordinator.simulating = simulating
        context.coordinator.autoFollow = autoFollow
        context.coordinator.following = following
        context.coordinator.onUserPan = onUserPan
        context.coordinator.elevations = elevations
        context.coordinator.progressDistance = progressDistance
        context.coordinator.walkerHeading = walkerHeading
        context.coordinator.sync(map,
                                 coordinates: coordinates,
                                 markers: markers,
                                 junctions: junctions,
                                 restaurants: restaurants,
                                 toilets: toilets,
                                 walker: walker,
                                 breadcrumb: breadcrumb)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var map: MKMapView?
        var onWalk: ((CLLocationCoordinate2D) -> Void)?
        var simulating = false
        var autoFollow = false
        var following = true
        var onUserPan: (() -> Void)?
        var elevations: [Double?] = []
        var progressDistance: Double = 0
        var walkerHeading: Double?

        private var routeSegments: [MKPolyline] = []
        private var segmentStyle: [ObjectIdentifier: (width: CGFloat, alpha: CGFloat)] = [:]
        private var breadcrumbPolyline: MKPolyline?
        private let walkerAnnotation = WalkerAnnotation()
        private var walkerAdded = false
        private var lastSignature = ""
        private var lastProgressBucket = -1
        private var lastMarkerSig = ""
        private var lastJunctionSig = ""

        private var lastRestaurantSig = ""
        private var lastToiletSig = ""

        func sync(_ map: MKMapView,
                  coordinates: [CLLocationCoordinate2D],
                  markers: [DistanceMarker],
                  junctions: [Junction],
                  restaurants: [TrailRestaurant],
                  toilets: [TrailToilet],
                  walker: CLLocationCoordinate2D?,
                  breadcrumb: [CLLocationCoordinate2D]) {

            // While simulating, freeze map scroll so a drag moves the walker
            // rather than panning the map (zoom stays available).
            map.isScrollEnabled = !simulating

            let signature = routeSignature(coordinates)
            // Rebuild the route when it changes, or when the walker has advanced
            // enough that the "next 1 km" fade window has moved (100 m buckets).
            let progressBucket = Int(progressDistance / 100)
            if signature != lastSignature || progressBucket != lastProgressBucket {
                rebuildRoute(map, coordinates: coordinates)
                lastProgressBucket = progressBucket
            }
            if signature != lastSignature {
                // START / STOP signs at the route ends (flip with Reverse).
                let ends = map.annotations.compactMap { $0 as? EndpointAnnotation }
                map.removeAnnotations(ends)
                if let first = coordinates.first, let last = coordinates.last {
                    map.addAnnotation(EndpointAnnotation(coordinate: first, kind: .start))
                    map.addAnnotation(EndpointAnnotation(coordinate: last, kind: .stop))
                }
                fit(map, coordinates: coordinates)
                lastSignature = signature
            }

            // Numbered markers — only rebuild when they actually change
            // (otherwise MapKit re-animates them on every progress tick).
            let markerSig = markers.map(\.label).joined(separator: ",")
            if markerSig != lastMarkerSig {
                map.removeAnnotations(map.annotations.compactMap { $0 as? MarkerAnnotation })
                map.addAnnotations(markers.map(MarkerAnnotation.init))
                lastMarkerSig = markerSig
            }

            // Turn-arrow icons — likewise, rebuild only on change.
            let junctionSig = junctions.map { "\(Int($0.routeDistance))/\(Int($0.outBearing))" }
                .joined(separator: ",")
            if junctionSig != lastJunctionSig {
                map.removeAnnotations(map.annotations.compactMap { $0 as? JunctionAnnotation })
                map.addAnnotations(junctions.map(JunctionAnnotation.init))
                lastJunctionSig = junctionSig
            }

            // Restaurant pins near the trail — rebuild only on change.
            let restaurantSig = restaurants.map { String($0.id) }.joined(separator: ",")
            if restaurantSig != lastRestaurantSig {
                map.removeAnnotations(map.annotations.compactMap { $0 as? RestaurantAnnotation })
                map.addAnnotations(restaurants.map(RestaurantAnnotation.init))
                lastRestaurantSig = restaurantSig
            }

            // Public-toilet pins near the trail — rebuild only on change.
            let toiletSig = toilets.map { String($0.id) }.joined(separator: ",")
            if toiletSig != lastToiletSig {
                map.removeAnnotations(map.annotations.compactMap { $0 as? ToiletAnnotation })
                map.addAnnotations(toilets.map(ToiletAnnotation.init))
                lastToiletSig = toiletSig
            }

            // Faint breadcrumb of the actual walk.
            if let old = breadcrumbPolyline { map.removeOverlay(old) }
            breadcrumbPolyline = nil
            if breadcrumb.count > 1 {
                let line = MKPolyline(coordinates: breadcrumb, count: breadcrumb.count)
                map.addOverlay(line, level: .aboveLabels)
                breadcrumbPolyline = line
            }

            // Walker dot.
            if let walker {
                walkerAnnotation.coordinate = walker
                if !walkerAdded { map.addAnnotation(walkerAnnotation); walkerAdded = true }
                updateWalkerCompass(map)
            } else if walkerAdded {
                map.removeAnnotation(walkerAnnotation)
                walkerAdded = false
            }

            // Auto-recenter on the walker (real walk), preserving the user's
            // zoom. Keep the current position in the MIDDLE of the screen.
            if autoFollow, following, let walker {
                map.setCenter(walker, animated: true)
            }
        }

        /// Draw the planned route as a series of polylines whose WIDTH encodes
        /// the local grade: normal (4 px) where flat, thickening LINEARLY up to
        /// 4× (16 px) at a 25 % grade, at 80 % opacity — and where everything more
        /// than 1 km ahead of the walker fades back to 50 % so the next kilometre
        /// stands out. Consecutive segments that share a style are merged to keep
        /// the overlay count sane.
        private func rebuildRoute(_ map: MKMapView, coordinates: [CLLocationCoordinate2D]) {
            map.removeOverlays(routeSegments)
            routeSegments.removeAll()
            segmentStyle.removeAll()
            guard coordinates.count > 1 else { return }

            let cum = Geo.cumulativeDistances(coordinates)
            let hiking = progressDistance > 0
            let haveEle = elevations.count == coordinates.count

            // Grade is sampled over a ~50 m window (±25 m) rather than between
            // adjacent GPX points (median ~10 m apart). Per-point elevation
            // noise over such a short step would otherwise spike the grade and
            // make the line width lurch from thick to thin; smoothing over a
            // fixed distance makes the thickness change gradually with the
            // terrain instead.
            let halfWindow = 25.0
            func smoothedGrade(at i: Int) -> Double {
                guard haveEle else { return 0 }
                var lo = i
                while lo > 0 && (cum[i] - cum[lo] < halfWindow || elevations[lo] == nil) { lo -= 1 }
                var hi = i
                while hi < coordinates.count - 1 && (cum[hi] - cum[i] < halfWindow || elevations[hi] == nil) { hi += 1 }
                guard let a = elevations[lo], let b = elevations[hi] else { return 0 }
                let span = max(1, cum[hi] - cum[lo])
                return abs(b - a) / span
            }

            func style(at i: Int) -> (width: CGFloat, alpha: CGFloat) {
                let g = min(smoothedGrade(at: i), 0.25) / 0.25
                let width = 4.0 * (1.0 + 3.0 * g)                 // 4 px flat → 16 px (4×) at ≥25 %
                // Quantize to 0.5 px so consecutive segments still merge, but the
                // steps are fine enough to read as a gradual taper, not a lurch.
                let quantized = (width * 2).rounded() / 2
                let aheadStart = cum[i - 1] - progressDistance
                let alpha: CGFloat = (hiking && aheadStart > 1000) ? 0.5 : 0.8
                return (CGFloat(quantized), alpha)
            }

            // Merge consecutive segments sharing a (width, alpha) style.
            var runStart = 0
            var current = style(at: 1)
            func emitRun(_ from: Int, _ to: Int, _ s: (width: CGFloat, alpha: CGFloat)) {
                let slice = Array(coordinates[from...to])
                guard slice.count > 1 else { return }
                let poly = MKPolyline(coordinates: slice, count: slice.count)
                segmentStyle[ObjectIdentifier(poly)] = (s.width, s.alpha)
                routeSegments.append(poly)
                map.addOverlay(poly, level: .aboveLabels)
            }
            for i in 2..<coordinates.count {
                let s = style(at: i)
                if s != current {
                    emitRun(runStart, i - 1, current)
                    runStart = i - 1
                    current = s
                }
            }
            emitRun(runStart, coordinates.count - 1, current)
        }

        private func fit(_ map: MKMapView, coordinates: [CLLocationCoordinate2D]) {
            guard !coordinates.isEmpty else { return }
            let rect = coordinates.reduce(MKMapRect.null) { acc, c in
                acc.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 0, height: 0)))
            }
            map.setVisibleMapRect(rect,
                                  edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                  animated: false)
        }

        private func routeSignature(_ coords: [CLLocationCoordinate2D]) -> String {
            guard let first = coords.first, let last = coords.last else { return "empty" }
            return "\(coords.count)-\(first.latitude),\(first.longitude)-\(last.latitude),\(last.longitude)"
        }

        // MARK: Drag-to-walk

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            if simulating {
                let coord = map.convert(gesture.location(in: map), toCoordinateFrom: map)
                switch gesture.state {
                case .began, .changed, .ended: onWalk?(coord)
                default: break
                }
            } else if autoFollow, gesture.state == .began {
                // User is panning the map to look around → stop following.
                onUserPan?()
            }
        }

        /// Junction arrows are baked pointing at their absolute compass bearing
        /// on a north-up map. When the user rotates the map, counter-rotate those
        /// views by the map heading so each arrow keeps pointing the true way.
        private func compensateJunctionHeading(_ map: MKMapView) {
            let radians = -map.camera.heading * .pi / 180
            let t = CGAffineTransform(rotationAngle: radians)
            for annotation in map.annotations where annotation is JunctionAnnotation {
                map.view(for: annotation)?.transform = t
            }
        }

        /// A short red compass needle sticking out of the walker dot in the
        /// phone's heading direction (only while hiking, and only on hardware
        /// with a compass). Kept correct as the map is rotated.
        private func updateWalkerCompass(_ map: MKMapView) {
            guard let view = map.view(for: walkerAnnotation) else { return }
            let tag = 7788
            let container = view.viewWithTag(tag) ?? {
                let c = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
                c.tag = tag
                c.isUserInteractionEnabled = false
                c.clipsToBounds = false
                let needle = UIView(frame: CGRect(x: 13, y: 0, width: 2, height: 14))
                needle.backgroundColor = .systemRed
                needle.layer.cornerRadius = 1
                c.addSubview(needle)
                view.addSubview(c)
                return c
            }()
            container.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            if let heading = walkerHeading {
                container.isHidden = false
                let angle = (heading - map.camera.heading) * .pi / 180
                container.transform = CGAffineTransform(rotationAngle: angle)
            } else {
                container.isHidden = true
            }
        }

        /// Simulate: drag walks the dot. Real walk: observe pans (alongside the
        /// map's own pan) to know when to stop following. Idle: let the map pan.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            // Let the map's own rotate/pinch recognisers run; only gate our pan.
            if gesture is UIPanGestureRecognizer { return simulating || autoFollow }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            compensateJunctionHeading(map)
            updateWalkerCompass(map)
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            compensateJunctionHeading(map)
            updateWalkerCompass(map)
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                if line === breadcrumbPolyline {
                    r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35)
                    r.lineWidth = 6
                } else if let s = segmentStyle[ObjectIdentifier(line)] {
                    r.strokeColor = UIColor.systemBlue.withAlphaComponent(s.alpha)
                    r.lineWidth = s.width
                } else {
                    r.strokeColor = .systemBlue
                    r.lineWidth = 4
                }
                r.lineJoin = .round
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is WalkerAnnotation {
                let id = "walker"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = WalkerDot.image
                view.centerOffset = .zero
                view.canShowCallout = false
                return view
            }
            if let marker = annotation as? MarkerAnnotation {
                let id = "marker-dot"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = MarkerDot.image(for: marker.label)
                view.centerOffset = .zero
                return view
            }
            if let endpoint = annotation as? EndpointAnnotation {
                let id = "endpoint"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = EndpointSign.image(for: endpoint.kind)
                view.centerOffset = CGPoint(x: 0, y: -12)   // point sits at the coordinate
                view.alpha = 0.7   // 30% transparent so overlapping start/stop (loops) are both visible
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            }
            if let restaurant = annotation as? RestaurantAnnotation {
                let id = "restaurant"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = RestaurantIcon.image
                view.centerOffset = CGPoint(x: 0, y: -11)
                view.canShowCallout = true
                return view
            }
            if annotation is ToiletAnnotation {
                let id = "toilet"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = ToiletIcon.image
                view.centerOffset = CGPoint(x: 0, y: -11)
                view.canShowCallout = true
                return view
            }
            if let junction = annotation as? JunctionAnnotation {
                let id = "junction-arrow"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                // Baked to absolute bearing on a north-up map; counter-rotate to
                // the current map heading so it stays correct when rotated.
                view.transform = CGAffineTransform(rotationAngle: -map.camera.heading * .pi / 180)
                view.image = JunctionIcon.image(bearing: junction.outBearing)
                view.centerOffset = .zero    // disc sits on the junction
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            }
            return nil
        }
    }
}

// MARK: - Annotations & marker images

final class MarkerAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let label: String
    init(_ m: DistanceMarker) { coordinate = m.coordinate; label = m.label }
    var title: String? { label }
}

final class WalkerAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
}

final class JunctionAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let outBearing: Double       // absolute compass heading the route leaves on
    init(_ j: Junction) {
        coordinate = j.coordinate; outBearing = j.outBearing
    }
}

final class RestaurantAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let name: String
    init(_ r: TrailRestaurant) { coordinate = r.coordinate; name = r.name }
    var title: String? { name }
}

/// A small pin with a fork-and-knife glyph for a trailside eatery.
enum RestaurantIcon {
    static let image: UIImage = {
        let size = CGSize(width: 26, height: 26)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let disc = CGRect(x: 1, y: 1, width: 24, height: 24)
            UIColor.systemOrange.setFill(); c.fillEllipse(in: disc)
            UIColor.white.setStroke(); c.setLineWidth(1.5); c.strokeEllipse(in: disc)
            let glyph = UIImage(systemName: "fork.knife")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            glyph?.draw(in: CGRect(x: 6, y: 6, width: 14, height: 14))
        }
    }()
}

final class ToiletAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let name: String
    init(_ t: TrailToilet) { coordinate = t.coordinate; name = t.name }
    var title: String? { name }
}

/// A small teal pin with a toilet glyph for a trailside public toilet.
enum ToiletIcon {
    static let image: UIImage = {
        let size = CGSize(width: 26, height: 26)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let disc = CGRect(x: 1, y: 1, width: 24, height: 24)
            UIColor.systemTeal.setFill(); c.fillEllipse(in: disc)
            UIColor.white.setStroke(); c.setLineWidth(1.5); c.strokeEllipse(in: disc)
            let glyph = UIImage(systemName: "toilet")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            glyph?.draw(in: CGRect(x: 6, y: 6, width: 14, height: 14))
        }
    }()
}

final class EndpointAnnotation: NSObject, MKAnnotation {
    enum Kind { case start, stop }
    let coordinate: CLLocationCoordinate2D
    let kind: Kind
    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate; self.kind = kind
    }
}

/// A green START / red STOP pin.
enum EndpointSign {
    private static var cache: [String: UIImage] = [:]
    static func image(for kind: EndpointAnnotation.Kind) -> UIImage {
        let text = kind == .start ? "START" : "STOP"
        if let img = cache[text] { return img }
        let color = kind == .start ? UIColor.systemGreen : UIColor.systemRed
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let ts = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 8, padY: CGFloat = 4, tail: CGFloat = 7
        let w = ceil(ts.width) + padX * 2
        let h = ceil(ts.height) + padY * 2
        let size = CGSize(width: w, height: h + tail)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
            color.setFill(); path.fill()
            UIColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
            // little pointer tail to the coordinate
            let tri = UIBezierPath()
            tri.move(to: CGPoint(x: w/2 - 5, y: h))
            tri.addLine(to: CGPoint(x: w/2 + 5, y: h))
            tri.addLine(to: CGPoint(x: w/2, y: h + tail))
            tri.close(); color.setFill(); tri.fill()
            (text as NSString).draw(at: CGPoint(x: padX, y: padY), withAttributes: attrs)
        }
        cache[text] = img
        return img
    }
}

/// A discreet dark disc with a white arrow pointing in the actual compass
/// direction the hiker should head (north-up map).
enum JunctionIcon {
    static let circle: CGFloat = 30
    private static var cache: [Int: UIImage] = [:]

    static func image(bearing: Double) -> UIImage {
        let key = Int(bearing.rounded())
        if let img = cache[key] { return img }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: circle, height: circle))
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            let mid = circle / 2
            // Discreet dark semi-transparent disc — no outline.
            let discRect = CGRect(x: 2, y: 2, width: circle - 4, height: circle - 4)
            UIColor.black.withAlphaComponent(0.22).setFill()
            c.fillEllipse(in: discRect)

            // Plain white arrow, pointing up then rotated to the compass bearing
            // (clockwise in this y-down context) about the disc centre.
            c.translateBy(x: mid, y: mid)
            c.rotate(by: bearing * .pi / 180)
            UIColor.white.setStroke(); UIColor.white.setFill()
            c.setLineWidth(2.2); c.setLineCap(.round); c.setLineJoin(.round)
            let half = circle / 2
            c.move(to: CGPoint(x: 0, y: half - 5))
            c.addLine(to: CGPoint(x: 0, y: -half + 6))
            c.strokePath()
            c.move(to: CGPoint(x: 0, y: -half + 3))
            c.addLine(to: CGPoint(x: -4.5, y: -half + 9))
            c.addLine(to: CGPoint(x: 4.5, y: -half + 9))
            c.closePath(); c.fillPath()
        }
        cache[key] = img
        return img
    }
}

enum MarkerDot {
    private static var cache: [String: UIImage] = [:]

    /// A small orange pill showing the km distance (e.g. "0.5", "2").
    static func image(for label: String) -> UIImage {
        if let img = cache[label] { return img }
        let text = "\(label) km" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let ts = text.size(withAttributes: attrs)
        let padX: CGFloat = 6, padY: CGFloat = 3
        let size = CGSize(width: ceil(ts.width) + padX * 2, height: ceil(ts.height) + padY * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
            UIColor.systemOrange.setFill(); path.fill()
            UIColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
            text.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2),
                      withAttributes: attrs)
        }
        cache[label] = img
        return img
    }
}

enum WalkerDot {
    static let image: UIImage = {
        let size: CGFloat = 26
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let c = ctx.cgContext
            // soft halo
            UIColor.systemBlue.withAlphaComponent(0.25).setFill()
            c.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            // core
            let core = CGRect(x: size/2 - 7, y: size/2 - 7, width: 14, height: 14)
            UIColor.systemBlue.setFill()
            c.fillEllipse(in: core)
            UIColor.white.setStroke()
            c.setLineWidth(3)
            c.strokeEllipse(in: core)
        }
    }()
}
