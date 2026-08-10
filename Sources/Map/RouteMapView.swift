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
    var walker: CLLocationCoordinate2D?
    var breadcrumb: [CLLocationCoordinate2D] = []
    var simulating: Bool = false
    var onWalk: ((CLLocationCoordinate2D) -> Void)?
    /// Keep the walker centred (real walk). Zoom is always left as the user set it.
    var autoFollow: Bool = false
    var following: Bool = true
    var onUserPan: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = false   // keep north up so the arrows read correctly
        map.isPitchEnabled = false
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
        context.coordinator.sync(map,
                                 coordinates: coordinates,
                                 markers: markers,
                                 junctions: junctions,
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

        private var routePolyline: MKPolyline?
        private var breadcrumbPolyline: MKPolyline?
        private let walkerAnnotation = WalkerAnnotation()
        private var walkerAdded = false
        private var lastSignature = ""
        private var lastMarkerSig = ""
        private var lastJunctionSig = ""

        func sync(_ map: MKMapView,
                  coordinates: [CLLocationCoordinate2D],
                  markers: [DistanceMarker],
                  junctions: [Junction],
                  walker: CLLocationCoordinate2D?,
                  breadcrumb: [CLLocationCoordinate2D]) {

            // While simulating, freeze map scroll so a drag moves the walker
            // rather than panning the map (zoom stays available).
            map.isScrollEnabled = !simulating

            let signature = routeSignature(coordinates)
            if signature != lastSignature {
                if let old = routePolyline { map.removeOverlay(old) }
                if coordinates.count > 1 {
                    let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    map.addOverlay(line, level: .aboveLabels)
                    routePolyline = line
                }
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
                map.addAnnotations(junctions.enumerated().map { JunctionAnnotation($1, number: $0 + 1) })
                lastJunctionSig = junctionSig
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
            } else if walkerAdded {
                map.removeAnnotation(walkerAnnotation)
                walkerAdded = false
            }

            // Auto-recenter on the walker (real walk), preserving the user's
            // zoom. setCenter keeps the current span, so zoom is untouched.
            if autoFollow, following, let walker {
                map.setCenter(walker, animated: true)
            }
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

        /// Simulate: drag walks the dot. Real walk: observe pans (alongside the
        /// map's own pan) to know when to stop following. Idle: let the map pan.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            simulating || autoFollow
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                if line === breadcrumbPolyline {
                    r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35)
                    r.lineWidth = 6
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
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            }
            if let junction = annotation as? JunctionAnnotation {
                let id = "junction-arrow"
                let view = map.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.transform = .identity   // arrow is baked into the image
                let img = JunctionIcon.image(bearing: junction.outBearing, number: junction.number)
                view.image = img
                // Circle centre sits on the junction; number hangs below.
                view.centerOffset = CGPoint(x: 0, y: JunctionIcon.circle / 2 - img.size.height / 2)
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
    let number: Int              // temporary label so John can flag wrong ones
    init(_ j: Junction, number: Int) {
        coordinate = j.coordinate; outBearing = j.outBearing; self.number = number
    }
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

/// A circle with an arrow that points in the actual compass direction the
/// hiker should head (north-up map), plus a small number below for debugging.
enum JunctionIcon {
    static let circle: CGFloat = 30
    private static var cache: [String: UIImage] = [:]

    static func image(bearing: Double, number: Int) -> UIImage {
        let key = "\(Int(bearing.rounded()))-\(number)"
        if let img = cache[key] { return img }

        let numFont = UIFont.systemFont(ofSize: 11, weight: .bold)
        let numText = "\(number)" as NSString
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: numFont, .foregroundColor: UIColor.systemBlue
        ]
        let numSize = numText.size(withAttributes: numAttrs)
        let gap: CGFloat = 1
        let w = max(circle, numSize.width + 6)
        let h = circle + gap + numSize.height
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            let cx = w / 2, cy = circle / 2
            // Discreet dark semi-transparent disc — no outline, no fill circle.
            let discRect = CGRect(x: cx - circle/2 + 2, y: 2, width: circle - 4, height: circle - 4)
            UIColor.black.withAlphaComponent(0.38).setFill()
            c.fillEllipse(in: discRect)

            // Plain white arrow, pointing up then rotated to the compass bearing
            // (clockwise in this y-down context) about the disc centre.
            c.saveGState()
            c.translateBy(x: cx, y: cy)
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
            c.restoreGState()

            // Number below, upright (temporary debug label).
            numText.draw(at: CGPoint(x: (w - numSize.width) / 2, y: circle + gap),
                         withAttributes: numAttrs)
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
