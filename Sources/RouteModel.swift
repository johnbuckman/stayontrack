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
        didSet { recomputeMarkers(); recomputeJunctions(); rebuildETA() }
    }
    @Published var errorMessage: String?
    @Published var tileProgress: TileProgress?

    enum TrailNetworkState: Equatable {
        case idle, loading, ready(Int), failed
    }
    @Published var trailState: TrailNetworkState = .idle
    @Published var intersections: [Intersection] = []
    @Published var junctions: [Junction] = []
    /// Eateries within ~200 m of the trail, in the route's CANONICAL direction.
    @Published var restaurants: [TrailRestaurant] = []
    private var restaurantTask: Task<Void, Never>?

    @Published var toilets: [TrailToilet] = []
    private var toiletTask: Task<Void, Never>?
    /// Hourly temperature forecast covering the hike window.
    @Published var weather: [WeatherHour] = []
    private var weatherTask: Task<Void, Never>?
    /// Grade-adjusted timing model for the current direction (cached).
    private var routeETA: ETAEngine?
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

    /// Elevation profile (cumulative distance + elevation) in travel order, for
    /// the chart — available before the hike starts too.
    var elevationProfile: [ElevationSample] {
        let cumulative = Geo.cumulativeDistances(travelCoordinates)
        return zip(cumulative, travelPoints).compactMap { d, p in
            p.elevation.map { ElevationSample(distance: d, elevation: $0) }
        }
    }
    var routeTotalDistance: Double { route?.totalDistance ?? 0 }

    init() { restoreLastHike() }

    // MARK: Loading

    /// Persisted copy of the last-loaded GPX, restored on next launch.
    private var lastGPXURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-hike.gpx")
    }

    func load(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            load(data: try Data(contentsOf: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(data: Data) {
        do {
            let parsed = try GPXParser.parse(data: data)
            try? data.write(to: lastGPXURL, options: .atomic)   // remember for next launch
            apply(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-open whatever GPX was loaded last time the app ran.
    func restoreLastHike() {
        guard route == nil, let data = try? Data(contentsOf: lastGPXURL) else { return }
        load(data: data)
    }

    private func apply(_ parsed: GPXRoute) {
        route = parsed
        reversed = false            // triggers recompute via didSet
        recomputeMarkers()
        recomputeJunctions()        // geometry turns show immediately (pre-Overpass)
        errorMessage = nil
        rebuildETA()
        startTileDownload(for: parsed)
        startTrailFetch(for: parsed)
        startRestaurantFetch(for: parsed)
        startToiletFetch(for: parsed)
        startWeatherFetch(for: parsed)
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

    /// Nearby eateries (within ~200 m of the trail), cached per-route for
    /// offline use. Computed in the route's canonical direction.
    private func startRestaurantFetch(for route: GPXRoute) {
        restaurantTask?.cancel()
        restaurants = []
        let coords = route.coordinates
        guard coords.count > 1 else { return }
        let cum = Geo.cumulativeDistances(coords)
        let cacheKey = RestaurantCache.key(for: coords)
        if let cached = RestaurantCache.load(cacheKey) {
            restaurants = RestaurantFinder.dedupedByName(cached)   // older caches may hold dupes
            return
        }
        restaurantTask = Task { [weak self] in
            let found = await RestaurantFinder.fetch(coords: coords, cumulative: cum)
            guard let self, !Task.isCancelled else { return }
            RestaurantCache.save(cacheKey, found)
            self.restaurants = found
        }
    }

    /// Restaurants with `routeDistance` expressed in the CURRENT travel
    /// direction (flips when Reverse is on), sorted by how soon you reach them.
    var travelRestaurants: [TrailRestaurant] {
        guard reversed, let total = route?.totalDistance else {
            return restaurants
        }
        return restaurants.map { r in
            var m = r; m.routeDistance = max(0, total - r.routeDistance); return m
        }.sorted { $0.routeDistance < $1.routeDistance }
    }

    private func startToiletFetch(for route: GPXRoute) {
        toiletTask?.cancel()
        toilets = []
        let coords = route.coordinates
        guard coords.count > 1 else { return }
        let cum = Geo.cumulativeDistances(coords)
        let cacheKey = ToiletCache.key(for: coords)
        if let cached = ToiletCache.load(cacheKey) {
            toilets = cached
            return
        }
        toiletTask = Task { [weak self] in
            let found = await ToiletFinder.fetch(coords: coords, cumulative: cum)
            guard let self, !Task.isCancelled else { return }
            ToiletCache.save(cacheKey, found)
            self.toilets = found
        }
    }

    /// Toilets with `routeDistance` expressed in the CURRENT travel direction
    /// (flips when Reverse is on), sorted by how soon you reach them.
    var travelToilets: [TrailToilet] {
        guard reversed, let total = route?.totalDistance else {
            return toilets
        }
        return toilets.map { t in
            var m = t; m.routeDistance = max(0, total - t.routeDistance); return m
        }.sorted { $0.routeDistance < $1.routeDistance }
    }

    enum AltState: Equatable { case idle, working, failed(String) }
    @Published var altState: AltState = .idle
    private var altTask: Task<Void, Never>?

    /// Compute an alternative route (shorter / longer / avoid-steep) over the OSM
    /// walking graph between this hike's start and finish, and adopt it as the
    /// current route on success. Runs at the pre-start screen (needs network).
    func computeAlternative(mode: AlternativeMode) {
        guard let route else { return }
        altTask?.cancel()
        altState = .working
        let coords = route.coordinates                 // canonical start→finish
        let label: String = {
            switch mode {
            case .shorter: return "shorter"
            case .longer: return "longer"
            case .avoidSteep: return "gentler"
            }
        }()
        altTask = Task { [weak self] in
            do {
                let alt = try await AlternativeRouteEngine.alternative(for: coords, mode: mode)
                guard let self, !Task.isCancelled else { return }
                let points = alt.map { GPXPoint(coordinate: $0, elevation: nil) }
                self.apply(GPXRoute(name: "\(self.routeName) (\(label))", points: points))
                self.altState = .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.altState = .failed(Self.altMessage(error))
            }
        }
    }

    private static func altMessage(_ error: Error) -> String {
        switch error {
        case AlternativeRouteEngine.EngineError.tooLarge:
            return "This area is too large to compute a gentler route offline."
        case AlternativeRouteEngine.EngineError.noGraph:
            return "Couldn't fetch the trail network — check your connection."
        default:
            return "No alternative route found between the start and finish."
        }
    }

    private func rebuildETA() {
        let points = travelPoints
        routeETA = points.count > 1 ? ETAEngine(travelPoints: points) : nil
    }

    /// Predicted grade-adjusted seconds from the start to a point `d` metres
    /// along the route (in the current travel direction).
    func predictedSeconds(toDistance d: Double) -> Double {
        routeETA?.expectedTime(toDistance: d) ?? 0
    }

    /// Forecast temperature (°C) at a given clock time, linearly interpolated.
    func temperature(at date: Date) -> Double? {
        guard !weather.isEmpty else { return nil }
        if date <= weather.first!.time { return weather.first!.tempC }
        if date >= weather.last!.time { return weather.last!.tempC }
        for i in 1..<weather.count where weather[i].time >= date {
            let a = weather[i - 1], b = weather[i]
            let span = b.time.timeIntervalSince(a.time)
            let t = span > 0 ? date.timeIntervalSince(a.time) / span : 0
            return a.tempC + (b.tempC - a.tempC) * t
        }
        return weather.last?.tempC
    }

    /// Forecast for the hike, keyed by the route midpoint + calendar day so it
    /// refreshes daily and works offline once fetched.
    private func startWeatherFetch(for route: GPXRoute) {
        weatherTask?.cancel()
        weather = []
        let coords = route.coordinates
        guard !coords.isEmpty else { return }
        let mid = coords[coords.count / 2]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        let day = df.string(from: Date())
        let key = WeatherCache.key(lat: mid.latitude, lon: mid.longitude, dayStamp: day)
        if let cached = WeatherCache.load(key) { weather = cached; return }
        weatherTask = Task { [weak self] in
            let hours = await WeatherClient.fetch(lat: mid.latitude, lon: mid.longitude)
            guard let self, !Task.isCancelled, !hours.isEmpty else { return }
            WeatherCache.save(key, hours)
            self.weather = hours
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

    /// Total elevation gain of the planned route (sum of positive climbs, using
    /// the same 1 m noise floor as the live hike so pre- and in-hike numbers
    /// agree). Nil until elevation is available.
    var routeElevationGain: Double? {
        let eles = travelPoints.compactMap(\.elevation)
        guard eles.count > 1 else { return nil }
        var gain = 0.0
        for i in 1..<eles.count {
            let climb = eles[i] - eles[i - 1]
            if climb > 1.0 { gain += climb }
        }
        return gain
    }

    var elevationGainText: String? {
        routeElevationGain.map { String(format: "%.0f m ascent", $0) }
    }

    /// Grade-adjusted estimated time to walk the whole route, formatted h:mm.
    /// Uses the same Tobler model as the in-hike "calc" ETA.
    var estimatedDurationText: String? {
        let points = travelPoints
        guard points.count > 1 else { return nil }
        let seconds = ETAEngine(travelPoints: points).calculatedRemaining(fromDistance: 0)
        guard seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }
}
