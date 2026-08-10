import Foundation
import SwiftUI
import CoreLocation

/// Holds the currently loaded hike and the pre-start options (Phase 1).
/// Later phases add live tracking, off-trail audio, voice turns, and ETAs.
@MainActor
final class RouteModel: ObservableObject {
    @Published private(set) var route: GPXRoute?
    @Published private(set) var markers: [DistanceMarker] = []
    @Published var reversed: Bool = false {
        didSet { recomputeMarkers(); recomputeJunctions() }
    }
    @Published var errorMessage: String?
    @Published var tileProgress: TileProgress?

    enum TrailNetworkState: Equatable {
        case idle, loading, ready(Int), failed
    }
    @Published var trailState: TrailNetworkState = .idle
    @Published var intersections: [Intersection] = []
    @Published var junctions: [Junction] = []
    @Published var trailElapsed: TimeInterval = 0
    @Published var tileEtaSeconds: TimeInterval?

    private var trailTimer: Timer?
    private var trailStart: Date?
    private var tileStart: Date?

    enum ElevationState: Equatable { case native, fetching, filled, failed }
    @Published var elevationState: ElevationState = .native

    private let downloader = TileDownloader()
    private var downloadTask: Task<Void, Never>?
    private var trailTask: Task<Void, Never>?
    private var elevationTask: Task<Void, Never>?

    var hasRoute: Bool { route != nil }

    /// Points in the chosen travel direction (carry elevation for ETA + sampling).
    var travelPoints: [GPXPoint] {
        guard let route else { return [] }
        return reversed ? route.points.reversed() : route.points
    }

    /// Coordinates in the chosen travel direction (for drawing + tracking).
    var travelCoordinates: [CLLocationCoordinate2D] {
        travelPoints.map(\.coordinate)
    }

    var routeName: String { route?.name ?? "Hike" }

    // MARK: Loading

    func load(from url: URL) {
        do {
            let parsed = try GPXParser.parse(url: url)
            apply(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(data: Data) {
        do {
            apply(try GPXParser.parse(data: data))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the bundled sample hike (handy in the simulator with no share sheet).
    func loadSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "gpx") else {
            errorMessage = "Sample hike is missing from the app bundle."
            return
        }
        load(from: url)
    }

    private func apply(_ parsed: GPXRoute) {
        route = parsed
        reversed = false            // triggers recompute via didSet
        recomputeMarkers()
        recomputeJunctions()        // geometry turns show immediately (pre-Overpass)
        errorMessage = nil
        startTileDownload(for: parsed)
        startTrailFetch(for: parsed)
        startElevationFillIfNeeded(for: parsed)
    }

    /// If the GPX carries no elevation, fetch it from a DEM so the grade-adjusted
    /// ETA and climb stats work. Baked into `route` before the hike starts.
    private func startElevationFillIfNeeded(for parsed: GPXRoute) {
        elevationTask?.cancel()
        guard !parsed.hasElevation else { elevationState = .native; return }
        elevationState = .fetching
        let coords = parsed.coordinates
        elevationTask = Task { [weak self] in
            do {
                let elevations = try await ElevationClient.fetch(coords)
                guard let self, !Task.isCancelled,
                      elevations.count == self.route?.points.count else { return }
                var updated = self.route!
                for i in updated.points.indices { updated.points[i].elevation = elevations[i] }
                self.route = updated
                self.elevationState = .filled
            } catch {
                self?.elevationState = .failed
            }
        }
    }

    /// Fetches the OSM trail network so junctions can be precomputed for voice
    /// turns. Runs at import while online; failure is non-fatal (no junctions).
    private func startTrailFetch(for route: GPXRoute) {
        trailTask?.cancel()
        trailTimer?.invalidate()
        intersections = []
        junctions = []
        trailElapsed = 0
        let coords = route.coordinates
        guard !coords.isEmpty else { trailState = .idle; return }

        // Cached from a previous load of this exact route? Use it instantly —
        // no network, works offline.
        let cacheKey = IntersectionCache.key(for: coords)
        if let cached = IntersectionCache.load(cacheKey) {
            intersections = cached
            recomputeJunctions()
            trailState = .ready(junctions.count)
            return
        }

        trailStart = Date()
        trailState = .loading

        // Live elapsed clock while the fetch is in flight.
        trailTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.trailStart else { return }
                self.trailElapsed = Date().timeIntervalSince(start)
            }
        }

        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let pad = 0.003
        let bbox = (s: lats.min()! - pad, w: lons.min()! - pad,
                    n: lats.max()! + pad, e: lons.max()! + pad)
        trailTask = Task { [weak self] in
            do {
                let found = try await OverpassClient.fetchIntersections(bbox: bbox)
                guard let self, !Task.isCancelled else { return }
                self.trailTimer?.invalidate(); self.trailTimer = nil
                IntersectionCache.save(cacheKey, found)   // reuse next time, offline
                self.intersections = found
                self.recomputeJunctions()
                self.trailState = .ready(self.junctions.count)
            } catch {
                self?.trailTimer?.invalidate(); self?.trailTimer = nil
                self?.trailState = .failed
            }
        }
    }

    /// Pre-caches the OSM tile corridor so the map works offline on the hike.
    private func startTileDownload(for route: GPXRoute) {
        downloadTask?.cancel()
        tileProgress = TileProgress(done: 0, total: 0)
        tileEtaSeconds = nil
        tileStart = Date()
        let coords = route.coordinates
        downloadTask = Task { [weak self, downloader] in
            await downloader.download(coords: coords) { progress in
                guard let self else { return }
                self.tileProgress = progress
                if let start = self.tileStart, progress.done > 0, !progress.isComplete {
                    let elapsed = Date().timeIntervalSince(start)
                    let rate = Double(progress.done) / max(elapsed, 0.001)   // tiles/sec
                    if rate > 0 {
                        self.tileEtaSeconds = Double(progress.total - progress.done) / rate
                    }
                } else {
                    self.tileEtaSeconds = nil
                }
            }
        }
    }

    private func recomputeMarkers() {
        guard let route else { markers = []; return }
        markers = RouteGeometry.markers(for: route, reversed: reversed)
    }

    private func recomputeJunctions() {
        guard route != nil else { junctions = []; return }
        // Geometry turns don't need OSM, so this works even before/without Overpass.
        junctions = RoutePlanner.plan(travelPoints: travelPoints, intersections: intersections)
    }

    // MARK: Summary

    var distanceKmText: String {
        guard let route else { return "—" }
        return String(format: "%.2f km", route.totalDistance / 1000.0)
    }
}
