import Foundation
import SwiftUI
import UIKit
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
    /// Pre-download progress per basemap style. BOTH styles are cached at
    /// import, so a single figure would silently ignore half the work — and the
    /// whole point of this readout is telling John when it is safe to switch the
    /// phone to airplane mode.
    @Published var tileProgressByStyle: [MapStyle: TileProgress] = [:]

    /// The two corridors added together: what is actually left to download.
    var tileProgress: TileProgress? {
        guard !tileProgressByStyle.isEmpty else { return nil }
        let done = tileProgressByStyle.values.reduce(0) { $0 + $1.done }
        let total = tileProgressByStyle.values.reduce(0) { $0 + $1.total }
        return TileProgress(done: done, total: total)
    }

    /// True once every style's corridor is fully cached — i.e. the map works
    /// with the radios off.
    var offlineMapReady: Bool {
        guard let p = tileProgress, p.total > 0 else { return false }
        return p.isComplete
    }

    enum TrailNetworkState: Equatable {
        case idle, loading, ready(Int), failed
    }
    @Published var trailState: TrailNetworkState = .idle
    /// Basemap style, remembered across launches. **Topo is the default**: the
    /// contour lines are what makes a map useful on a climb, so a fresh install
    /// opens on OpenTopoMap rather than the plain OSM raster. A stored
    /// preference still wins, so switching to the plain map sticks.
    @Published var mapStyle: MapStyle = MapStyle(rawValue:
        UserDefaults.standard.string(forKey: "mapStyle") ?? "") ?? .topo {
        didSet {
            guard mapStyle != oldValue else { return }
            UserDefaults.standard.set(mapStyle.rawValue, forKey: "mapStyle")
            if mapStyle != .standard, let route { startTileDownload(for: route, style: mapStyle) }
        }
    }
    private var topoDownloadTask: Task<Void, Never>?
    /// OSM-snapped true trail length (metres). Nil until the trail fetch computes
    /// it (or from cache); until then the raw GPX sum is shown. See `RouteSnapper`.
    @Published var correctedDistance: Double?
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
    /// Pieces of the route whose trail network has arrived, out of the total.
    @Published var trailProgress: TileProgress?
    /// Estimated seconds until every piece has arrived.
    @Published var trailEtaSeconds: TimeInterval?
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

    init() {
        restoreLastHike()
        // A fetch interrupted by switching apps (iOS freezes network work in the
        // background) is retried as soon as the app is back on screen.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryTrailFetch() }
        }
    }

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
        startTileDownload(for: parsed)                    // plain OSM corridor
        startTileDownload(for: parsed, style: .topo)      // topo corridor, one level deeper
        #if DEBUG
        // Opt-in: run the app with -tileSelfCheck to have every zoom level
        // probed and logged. Off by default so an ordinary import isn't doing
        // ~46 extra tile loads.
        if UserDefaults.standard.bool(forKey: "tileSelfCheck"),
           let first = parsed.coordinates.first {
            for style in MapStyle.allCases { TileSelfCheck.run(at: first, style: style) }
        }
        #endif

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
                self.persistEnrichedCopy()
            } catch {
                self?.elevationState = .failed
            }
        }
    }

    /// Fetches the OSM trail network so junctions can be precomputed for voice
    /// turns. Runs at import while online; failure is non-fatal (no junctions).
    ///
    /// Order of preference: turns stored in the GPX itself (our own saved copy),
    /// then the on-disk cache, then the network — fetched in ~600 m pieces along
    /// the route so turns appear on the map as each piece arrives, with a
    /// done/total count and a time-left estimate. `seed` keeps junctions already
    /// known (a retry, or a partial set saved in the GPX) on screen meanwhile.
    private func startTrailFetch(for route: GPXRoute, seed: [Intersection] = []) {
        trailTask?.cancel()
        trailTimer?.invalidate()
        intersections = seed
        junctions = []
        correctedDistance = nil
        trailElapsed = 0
        trailProgress = nil
        trailEtaSeconds = nil
        let coords = route.coordinates
        guard !coords.isEmpty else { trailState = .idle; return }

        let cacheKey = IntersectionCache.key(for: coords)
        let distKey = SnappedDistanceCache.key(for: coords)

        // Saved in the GPX by an earlier import: nothing to calculate.
        if let t = route.trail, t.complete {
            intersections = t.intersections
            if t.lengthKey == distKey { correctedDistance = t.length }
            recomputeJunctions()
            trailState = .ready(junctions.count)
            return
        }

        // Cached from a previous load of this exact route? Use it instantly —
        // no network, works offline. Distance is cached separately (it may be
        // missing on routes imported before snapping existed); if so we still
        // need the network to compute it, so only take the fast path when both
        // the junctions and the snapped distance are cached.
        if let cached = IntersectionCache.load(cacheKey),
           let dist = SnappedDistanceCache.load(distKey) {
            intersections = cached
            correctedDistance = dist.distance
            recomputeJunctions()
            trailState = .ready(junctions.count)
            persistEnrichedCopy()
            return
        }

        let seed = seed.isEmpty ? (route.trail?.intersections ?? []) : seed
        intersections = seed
        recomputeJunctions()
        trailStart = Date()
        trailState = .loading

        // Live elapsed clock while the fetch is in flight.
        trailTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.trailStart else { return }
                self.trailElapsed = Date().timeIntervalSince(start)
            }
        }

        // Ask iOS for extra time if the user switches away mid-fetch (e.g. back
        // to MapOut after sharing the GPX); otherwise the requests are frozen.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "trail-network")

        trailTask = Task { [weak self] in
            defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }
            do {
                // One graph serves both features: junctions are the degree-≥3
                // nodes; the snapper measures the route along the same ways to
                // recover the length the sparse GPX sampling chorded off.
                let graph = try await TrailNetworkFetcher.fetch(coords: coords) { [weak self] g, done, total in
                    guard let self, !Task.isCancelled else { return }
                    self.trailProgress = TileProgress(done: done, total: total)
                    if let start = self.trailStart, done > 0, done < total {
                        let rate = Double(done) / max(Date().timeIntervalSince(start), 0.001)
                        self.trailEtaSeconds = Double(total - done) / rate
                    } else {
                        self.trailEtaSeconds = nil
                    }
                    guard done > 0 else { return }
                    let found = OverpassClient.deriveIntersections(nodes: g.nodes, ways: g.wayLists)
                    self.intersections = Self.union(seed, found)
                    self.recomputeJunctions()
                }
                let nodes = graph.nodes, ways = graph.wayLists
                let found = OverpassClient.deriveIntersections(nodes: nodes, ways: ways)
                let snapped = await Task.detached(priority: .utility) {
                    RouteSnapper.correctedDistance(coords: coords, nodes: nodes, ways: ways)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.trailTimer?.invalidate(); self.trailTimer = nil
                IntersectionCache.save(cacheKey, found)          // reuse next time, offline
                SnappedDistanceCache.save(distKey, snapped)
                self.intersections = found
                self.correctedDistance = snapped.distance
                self.recomputeJunctions()
                self.trailEtaSeconds = nil
                self.trailState = .ready(self.junctions.count)
                self.persistEnrichedCopy()
            } catch {
                guard let self, !Task.isCancelled else { return }
                // Some pieces failed: keep the turns that did arrive (already
                // published), remember them in the GPX copy, and offer a retry.
                self.trailTimer?.invalidate(); self.trailTimer = nil
                self.trailEtaSeconds = nil
                self.trailState = .failed
                self.persistEnrichedCopy()
            }
        }
    }

    /// Try the turn network again, keeping the turns already found on screen.
    /// Called by the Retry button and automatically when the app returns to the
    /// foreground after a failed attempt.
    func retryTrailFetch() {
        guard let route, trailState == .failed else { return }
        startTrailFetch(for: route, seed: intersections)
    }

    private static func union(_ a: [Intersection], _ b: [Intersection]) -> [Intersection] {
        guard !a.isEmpty else { return b }
        var seen = Set<String>()
        var out: [Intersection] = []
        for i in b + a {
            let k = String(format: "%.6f,%.6f", i.coordinate.latitude, i.coordinate.longitude)
            if seen.insert(k).inserted { out.append(i) }
        }
        return out
    }

    /// Rewrites the saved copy of the route (`last-hike.gpx`) with everything
    /// worked out so far — filled-in elevation, the turn network and the true
    /// trail length — so reopening it never recalculates.
    private func persistEnrichedCopy() {
        guard var r = route else { return }
        let complete: Bool = { if case .ready = trailState { return true }; return false }()
        guard complete || !intersections.isEmpty else { return }
        r.trail = StoredTrail(intersections: intersections,
                              complete: complete,
                              length: correctedDistance,
                              lengthKey: correctedDistance == nil ? nil
                                  : SnappedDistanceCache.key(for: r.coordinates))
        try? Data(GPXWriter.gpxString(route: r).utf8).write(to: lastGPXURL, options: .atomic)
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
            if let found { RestaurantCache.save(cacheKey, found) }   // a failed lookup is retried next import
            self.restaurants = found ?? []
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
            if let found { ToiletCache.save(cacheKey, found) }
            self.toilets = found ?? []
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

    /// Pre-caches a style's tile corridor so the map works offline on the hike.
    ///
    /// Both styles are downloaded at import, so the two run concurrently and
    /// would otherwise trample each other's published progress. Only the style
    /// currently on screen reports — the other warms its cache silently.
    private func startTileDownload(for route: GPXRoute, style: MapStyle = .standard) {
        if style == .standard { downloadTask?.cancel() } else { topoDownloadTask?.cancel() }
        tileProgressByStyle[style] = TileProgress(done: 0, total: 0)
        tileEtaSeconds = nil
        if tileStart == nil || offlineMapReady { tileStart = Date() }
        let coords = route.coordinates
        let task = Task { [weak self, downloader] in
            await downloader.download(coords: coords, style: style) { progress in
                guard let self else { return }
                self.tileProgressByStyle[style] = progress
                // ETA is for the WHOLE pre-download, both styles together.
                guard let overall = self.tileProgress else { return }
                if let start = self.tileStart, overall.done > 0, !overall.isComplete {
                    let elapsed = Date().timeIntervalSince(start)
                    let rate = Double(overall.done) / max(elapsed, 0.001)   // tiles/sec
                    self.tileEtaSeconds = rate > 0
                        ? Double(overall.total - overall.done) / rate : nil
                } else {
                    self.tileEtaSeconds = nil
                }
            }
        }
        if style == .standard { downloadTask = task } else { topoDownloadTask = task }
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

    /// The distance to *show* for the route: the OSM-snapped true trail length
    /// once computed, else the raw GPX sum. The raw sum chords across every bend
    /// of a sparsely-sampled planned route and reads ~10–15% short of what other
    /// apps report; snapping to the OSM ways recovers the lost curve.
    var displayedDistance: Double {
        correctedDistance ?? (route?.totalDistance ?? 0)
    }

    /// How much longer the snapped route is than the raw GPX sum (1 = no data
    /// yet). Applied to the pre-start time estimate so it, too, reflects the
    /// real distance. Live in-hike ETA stays in raw metres.
    var distanceScale: Double {
        guard let corrected = correctedDistance,
              let raw = route?.totalDistance, raw > 0 else { return 1 }
        return corrected / raw
    }

    var distanceKmText: String {
        guard route != nil else { return "—" }
        return String(format: "%.2f km", displayedDistance / 1000.0)
    }

    /// Total elevation gain of the planned route: elevation averaged over
    /// ±150 m of track, then climbs counted past a 5 m threshold — the same
    /// method as the live hike, so pre- and in-hike numbers agree. Nil until
    /// elevation is available. See `ElevationSmoothing`.
    var routeElevationGain: Double? {
        let points = travelPoints
        guard points.compactMap(\.elevation).count > 1 else { return nil }
        let cumulative = Geo.cumulativeDistances(points.map(\.coordinate))
        return ElevationSmoothing.climb(cumulative: cumulative,
                                        elevations: points.map(\.elevation)).up
    }

    var elevationGainText: String? {
        routeElevationGain.map { String(format: "%.0f m ascent", $0) }
    }

    /// Grade-adjusted estimated time to walk the whole route, formatted h:mm.
    /// Uses the same Tobler model as the in-hike "calc" ETA.
    var estimatedDurationText: String? {
        let points = travelPoints
        guard points.count > 1 else { return nil }
        let seconds = ETAEngine(travelPoints: points, distanceScale: distanceScale)
            .calculatedRemaining(fromDistance: 0)
        guard seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }
}
