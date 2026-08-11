import Foundation
import SwiftUI
import CoreLocation

/// Drives a live (or simulated) hike: consumes positions, records the actual
/// track, publishes live stats (distance walked, elevation gained, off-trail
/// distance), sounds the off-trail tone (Phase 4), speaks turns at junctions
/// (Phase 5), and predicts ETAs (Phase 6).
@MainActor
final class HikeSession: ObservableObject {
    enum Phase { case idle, active, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var walker: CLLocationCoordinate2D?
    @Published private(set) var breadcrumb: [CLLocationCoordinate2D] = []

    @Published private(set) var distanceWalked: CLLocationDistance = 0
    @Published private(set) var elevationGain: Double = 0
    @Published private(set) var offTrackMeters: CLLocationDistance = 0
    @Published private(set) var elapsed: TimeInterval = 0

    /// Persistent history of completed walks.
    let walkStore = WalkStore()

    @Published private(set) var etaCalcText: String = "—"
    @Published private(set) var etaPaceText: String = "—"
    @Published private(set) var paceDeltaPercent: Double?    // + faster, − slower than calc
    @Published private(set) var lastAnnouncement: String?

    // The junction to surface in the top HUD (and later the Lock Screen).
    @Published private(set) var hudJunction: Junction?
    @Published private(set) var hudMeters: Double = 0

    // Elevation profile (whole route) + how far along you are, for the chart.
    @Published private(set) var elevationProfile: [ElevationSample] = []
    @Published private(set) var routeProgress: Double = 0
    var routeTotal: Double { plannedCumulative.last ?? 0 }

    private let elevationNoiseFloor = 1.0
    let offTrailThreshold: CLLocationDistance = 100
    private let paceReadyAfter: TimeInterval = 600   // withhold pace-ETA for 10 min

    private var tracker: PolylineTracker?
    private var recorded: [RecordedPoint] = []
    private var lastElevation: Double?
    private var startDate: Date?
    private var timer: Timer?
    private var routeName = "Hike"

    // Route geometry / planning
    private var plannedCoords: [CLLocationCoordinate2D] = []
    private var plannedCumulative: [CLLocationDistance] = []
    private var junctions: [Junction] = []
    private var announcedApproach = Set<Int>()   // ~50 m before
    private var announcedAt = Set<Int>()         // at the junction
    private var eta: ETAEngine?
    private var walkerRouteDistance: CLLocationDistance = 0

    // Feedback
    private let audio = HikeAudio()
    private let voice = VoiceAnnouncer()
    private let presenter = HikeStatusPresenter()

    private let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var isActive: Bool { phase == .active }
    var isOffTrail: Bool { offTrackMeters > offTrailThreshold }
    var junctionCount: Int { junctions.count }

    // MARK: Lifecycle

    func start(points: [GPXPoint],
               name: String,
               startCoordinate: CLLocationCoordinate2D,
               intersections: [Intersection]) {
        tracker = PolylineTracker(points: points)
        plannedCoords = points.map(\.coordinate)
        plannedCumulative = Geo.cumulativeDistances(plannedCoords)
        elevationProfile = zip(plannedCumulative, points).compactMap { d, p in
            p.elevation.map { ElevationSample(distance: d, elevation: $0) }
        }
        routeProgress = 0
        junctions = RoutePlanner.plan(travelPoints: points, intersections: intersections)
        eta = ETAEngine(travelPoints: points)
        announcedApproach = []; announcedAt = []

        recorded = []; breadcrumb = []
        distanceWalked = 0; elevationGain = 0; offTrackMeters = 0; elapsed = 0
        lastElevation = nil; walkerRouteDistance = 0
        etaCalcText = "—"; etaPaceText = "—"; paceDeltaPercent = nil
        lastAnnouncement = nil; hudJunction = nil; hudMeters = 0
        routeName = name
        startDate = Date()
        phase = .active
        walker = startCoordinate

        audio.startEngineIfNeeded()
        presenter.begin(routeName: name)
        ingest(coordinate: startCoordinate, elevation: nil, time: Date())
        startTimer()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        audio.stop(); voice.stop(); presenter.end()
        phase = .finished
        // Don't save a walk with no distance.
        if distanceWalked > 0 {
            walkStore.save(track: recorded, name: "\(routeName) (walked)",
                           distance: distanceWalked, elevation: elevationGain, duration: elapsed)
        }
    }

    func reset() {
        timer?.invalidate(); timer = nil
        audio.stop(); voice.stop(); presenter.end()
        phase = .idle
        walker = nil; breadcrumb = []; recorded = []
    }

    // MARK: Position input

    func ingest(coordinate: CLLocationCoordinate2D, elevation: Double?, time: Date) {
        guard phase == .active else { return }

        let match = tracker?.match(coordinate)
        offTrackMeters = match?.offTrackMeters ?? 0
        let ele = elevation ?? match?.elevation

        if let last = breadcrumb.last {
            let step = CLLocation(from: last).distance(from: CLLocation(from: coordinate))
            distanceWalked += step
            if let ele, let prev = lastElevation {
                let climb = ele - prev
                if climb > elevationNoiseFloor { elevationGain += climb }
            }
        }
        if ele != nil { lastElevation = ele }
        walker = coordinate
        breadcrumb.append(coordinate)
        recorded.append(RecordedPoint(coordinate: coordinate, elevation: ele, time: time))

        if let match { walkerRouteDistance = routeDistance(for: match); routeProgress = walkerRouteDistance }
        audio.update(offTrackMeters: offTrackMeters)
        announceJunctionsIfNeeded()
        updateHUD()
        updateETAs()
    }

    private func routeDistance(for match: PolylineTracker.Match) -> CLLocationDistance {
        let i = match.segmentIndex
        guard i + 1 < plannedCumulative.count else { return plannedCumulative.last ?? 0 }
        let segLen = plannedCumulative[i + 1] - plannedCumulative[i]
        return plannedCumulative[i] + match.t * segLen
    }

    // MARK: Voice turns

    private func announceJunctionsIfNeeded() {
        guard offTrackMeters < 60 else { return }   // don't call turns while well off-route
        // Minimal cue ("Keep left") twice: ~50 m before, then at the junction.
        for (index, j) in junctions.enumerated() {
            if !announcedApproach.contains(index), walkerRouteDistance >= j.routeDistance - 50 {
                announcedApproach.insert(index)
                lastAnnouncement = j.spoken
                voice.speak(j.spoken)
            }
            if !announcedAt.contains(index), walkerRouteDistance >= j.routeDistance - 12 {
                announcedAt.insert(index)
                lastAnnouncement = j.spoken
                voice.speak(j.spoken)
            }
        }
    }

    // MARK: HUD — the next junction and distance to it

    private func updateHUD() {
        // Nearest junction not yet 50 m behind us.
        let upcoming = junctions
            .filter { $0.routeDistance >= walkerRouteDistance - 50 }
            .min { $0.routeDistance < $1.routeDistance }
        if let j = upcoming, j.routeDistance - walkerRouteDistance <= 300 {
            hudJunction = j
            hudMeters = max(0, j.routeDistance - walkerRouteDistance)
            presenter.update(instruction: j.instruction, meters: Int(hudMeters), active: true)
        } else {
            hudJunction = nil
            presenter.update(instruction: "", meters: 0, active: false)
        }
    }

    // MARK: ETAs

    private func updateETAs() {
        guard let eta else { return }
        let now = Date()
        let calcRemaining = eta.calculatedRemaining(fromDistance: walkerRouteDistance)
        etaCalcText = clock.string(from: now.addingTimeInterval(calcRemaining))

        if elapsed >= paceReadyAfter, distanceWalked > 0 {
            let pace = distanceWalked / elapsed                       // m/s
            let remainingDist = max(0, eta.totalDistance - walkerRouteDistance)
            if pace > 0 {
                etaPaceText = clock.string(from: now.addingTimeInterval(remainingDist / pace))
            }
        }

        // How actual pace compares to the grade-adjusted model, as a %.
        // + = faster than calculated, − = slower. Needs a little distance first.
        if elapsed > 60, walkerRouteDistance > 30 {
            let expected = eta.expectedTime(toDistance: walkerRouteDistance)
            paceDeltaPercent = expected > 0 ? (expected / elapsed - 1) * 100 : nil
        }
    }

    var paceDeltaText: String {
        guard let p = paceDeltaPercent else { return "—" }
        let sign = p >= 0 ? "+" : "−"
        return "\(sign)\(Int(abs(p).rounded()))%"
    }

    // MARK: Clock

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate, self.phase == .active else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: Formatting

    var distanceWalkedText: String { String(format: "%.2f km", distanceWalked / 1000) }
    var elevationGainText: String { String(format: "%.0f m", elevationGain) }
    var offTrackText: String { String(format: "%.0f m", offTrackMeters) }
    var elapsedText: String {
        let s = Int(elapsed)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
