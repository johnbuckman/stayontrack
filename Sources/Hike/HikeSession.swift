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

    // Off-trail spoken distances (replaces the old rising-pitch tone).
    private let offTrailBands: [Double] = [20, 50, 100]
    private var offTrailBandAnnounced = 0             // highest band spoken; resets near trail
    private var strayOutstanding = false              // spoke off-trail/wrong-turn, not yet back

    // Auto-stop guards.
    private let autoStopEndRadius: CLLocationDistance = 10       // within 10 m of the finish…
    private let autoStopMinElapsed: TimeInterval = 20 * 60       // …but only after 20 min hiking
    private let carSpeed: CLLocationDistance = 20_000 / 3600     // 20 km/h in m/s
    private let carSustain: TimeInterval = 60                    // sustained for a minute → in a car
    private var fastSince: Date?
    private var lastFixTime: Date?

    // "Wrong turn" / repeat-instruction bookkeeping.
    private var wrongTurnSaid = Set<Int>()           // junctions we've warned a wrong turn past
    private var wrongTurnActive = false              // said "wrong turn" this stray; wait until back on trail
    private var repeatAnchor: CLLocationCoordinate2D?
    private var repeatAnchorSince: Date?
    private var repeatJunctionIndex: Int?

    /// Called just before an automatic stop so the UI can also stop the GPS.
    var onAutoStop: (() -> Void)?

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
    private var reversed = false                 // route direction, for the resume checkpoint
    private var fixesSinceCheckpoint = 0         // throttle checkpoint writes

    // Feedback
    private let audio = HikeAudio()
    private let voice = VoiceAnnouncer()
    private let presenter = HikeStatusPresenter()

    private let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var isActive: Bool { phase == .active }
    var startedAt: Date? { startDate }
    var isOffTrail: Bool { offTrackMeters > offTrailThreshold }
    var junctionCount: Int { junctions.count }

    // MARK: Lifecycle

    func start(points: [GPXPoint],
               name: String,
               startCoordinate: CLLocationCoordinate2D,
               intersections: [Intersection],
               reversed: Bool = false) {
        self.reversed = reversed
        fixesSinceCheckpoint = 0
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
        offTrailBandAnnounced = 0; fastSince = nil; lastFixTime = nil; strayOutstanding = false
        wrongTurnSaid = []; wrongTurnActive = false; repeatAnchor = nil; repeatAnchorSince = nil; repeatJunctionIndex = nil

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
        saveCheckpoint()
    }

    /// Reconstruct a hike that was interrupted (crash / kill) from its
    /// checkpoint, so tracking, stats, voice and ETA continue where they were.
    /// Replays no audio — it restores the aggregate state directly.
    func resume(points: [GPXPoint],
                name: String,
                intersections: [Intersection],
                from cp: HikeCheckpoint) {
        reversed = cp.reversed
        fixesSinceCheckpoint = 0
        tracker = PolylineTracker(points: points)
        tracker?.seed(routeDistance: cp.walkerRouteDistance)   // resume where we left off
        plannedCoords = points.map(\.coordinate)
        plannedCumulative = Geo.cumulativeDistances(plannedCoords)
        elevationProfile = zip(plannedCumulative, points).compactMap { d, p in
            p.elevation.map { ElevationSample(distance: d, elevation: $0) }
        }
        junctions = RoutePlanner.plan(travelPoints: points, intersections: intersections)
        eta = ETAEngine(travelPoints: points)

        recorded = cp.recorded.map(\.recordedPoint)
        breadcrumb = recorded.map(\.coordinate)
        distanceWalked = cp.distanceWalked
        elevationGain = cp.elevationGain
        offTrackMeters = cp.offTrackMeters
        walkerRouteDistance = cp.walkerRouteDistance
        routeProgress = walkerRouteDistance
        lastElevation = cp.lastElevation
        routeName = name
        startDate = cp.startDate
        walker = breadcrumb.last
        elapsed = Date().timeIntervalSince(cp.startDate)

        offTrailBandAnnounced = 0; fastSince = nil; lastFixTime = nil; strayOutstanding = false
        wrongTurnSaid = []; wrongTurnActive = false; repeatAnchor = nil; repeatAnchorSince = nil; repeatJunctionIndex = nil

        // Don't re-announce junctions we've already walked past.
        announcedApproach = []; announcedAt = []
        for (index, j) in junctions.enumerated() {
            if walkerRouteDistance >= j.routeDistance - 50 { announcedApproach.insert(index) }
            if walkerRouteDistance >= j.routeDistance - 12 { announcedAt.insert(index) }
        }

        phase = .active
        audio.startEngineIfNeeded()
        presenter.begin(routeName: name)
        updateHUD()
        updateETAs()
        startTimer()
        saveCheckpoint()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        audio.stop(); voice.stop(); presenter.end()
        phase = .finished
        HikeCheckpointStore.clear()
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
        HikeCheckpointStore.clear()
    }

    /// Swap in a freshly-computed junction set for the hike already in progress.
    /// Needed when a new GPX is loaded mid-trail: the route's OSM junctions come
    /// from Overpass asynchronously, so `start` may have begun with none. We keep
    /// junctions already behind us marked as "announced" (so we don't suddenly
    /// call out turns we've walked past) and leave upcoming ones pending so they
    /// speak normally. Ignored unless a hike is active and the set really changed.
    func updateJunctions(_ newJunctions: [Junction]) {
        guard phase == .active else { return }
        guard newJunctions.map(\.routeDistance) != junctions.map(\.routeDistance) else { return }
        junctions = newJunctions
        announcedApproach = []; announcedAt = []; wrongTurnSaid = []
        repeatAnchor = nil; repeatAnchorSince = nil; repeatJunctionIndex = nil
        for (i, j) in junctions.enumerated() where j.routeDistance < walkerRouteDistance - 10 {
            announcedAt.insert(i)       // already passed → don't announce retroactively
            wrongTurnSaid.insert(i)
        }
        updateHUD()
    }

    /// Persist a crash-recovery snapshot. Cheap enough to call often, but
    /// throttled from `ingest` so it isn't written on literally every GPS fix.
    private func saveCheckpoint() {
        guard phase == .active, let startDate else { return }
        HikeCheckpointStore.save(HikeCheckpoint(
            routeName: routeName,
            reversed: reversed,
            startDate: startDate,
            savedAt: Date(),
            distanceWalked: distanceWalked,
            elevationGain: elevationGain,
            offTrackMeters: offTrackMeters,
            walkerRouteDistance: walkerRouteDistance,
            lastElevation: lastElevation,
            recorded: recorded.map(HikeCheckpoint.Fix.init)
        ))
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
        announceJunctionsIfNeeded()
        updateHUD()
        updateETAs()
        updateOffTrailSpeech()
        checkWrongTurn()
        checkStalledAtJunction(coordinate: coordinate, time: time)
        checkAutoStop(coordinate: coordinate, time: time)
        guard phase == .active else { return }   // an auto-stop may have ended the hike

        // Checkpoint every few fixes so a crash loses at most a few seconds.
        fixesSinceCheckpoint += 1
        if fixesSinceCheckpoint >= 5 {
            fixesSinceCheckpoint = 0
            saveCheckpoint()
        }
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
        // One cue only, spoken ~20 m BEFORE the junction so there's time to react
        // (up from the old at-the-junction 7 m cue). `announcedAt` keeps it to a
        // single utterance per junction; the small negative tolerance covers a
        // GPS fix that first lands just past the trigger point.
        for (index, j) in junctions.enumerated() {
            let ahead = j.routeDistance - walkerRouteDistance   // + = junction still in front
            if !announcedAt.contains(index), ahead <= 20, ahead > -10 {
                announcedAt.insert(index)
                lastAnnouncement = j.spoken
                voice.speak(j.spoken)
            }
        }
    }

    /// Speak "20 / 50 / 100 meters off trail" as you stray further (each band
    /// once), and reset once you're essentially back on the trail. Replaces the
    /// old off-trail tone, which John found unhelpful.
    private func updateOffTrailSpeech() {
        // Back within 5 m after having strayed → confirm you're back on trail.
        if offTrackMeters < 5 {
            offTrailBandAnnounced = 0
            wrongTurnActive = false        // back on trail → a fresh stray may warn again
            if strayOutstanding {
                strayOutstanding = false
                lastAnnouncement = "Back on trail"
                voice.speak("Back on trail")
            }
            return
        }
        if offTrackMeters < 10 {
            offTrailBandAnnounced = 0
            return
        }
        var band = 0
        for (i, threshold) in offTrailBands.enumerated() where offTrackMeters >= threshold {
            band = i + 1
        }
        if band > offTrailBandAnnounced {
            offTrailBandAnnounced = band
            strayOutstanding = true
            let meters = Int(offTrailBands[band - 1])
            voice.speak("\(meters) meters off trail")
        }
    }

    /// After walking past a junction, if we've drifted more than 20 m off the
    /// trail, say "wrong turn" — but only ONCE per stray episode. When off-trail
    /// the projected `walkerRouteDistance` drifts and can fall inside a later
    /// junction's window, which used to fire a second, spurious "wrong turn"
    /// well past the actual mistake. So we gate on `wrongTurnActive` (cleared
    /// only when we're back on the trail, in `updateOffTrailSpeech`) and warn
    /// for the single nearest junction just behind us, not every junction whose
    /// window the drift happens to touch.
    private func checkWrongTurn() {
        guard offTrackMeters > 20, !wrongTurnActive else { return }
        // The junction we most recently passed (largest routeDistance at or
        // behind us, within 60 m) — the one we plausibly took the wrong fork at.
        guard let (index, _) = junctions.enumerated()
            .filter({ walkerRouteDistance >= $0.element.routeDistance
                        && walkerRouteDistance <= $0.element.routeDistance + 60
                        && !wrongTurnSaid.contains($0.offset) })
            .max(by: { $0.element.routeDistance < $1.element.routeDistance })
        else { return }
        wrongTurnSaid.insert(index)
        wrongTurnActive = true
        strayOutstanding = true
        lastAnnouncement = "Wrong turn"
        voice.speak("Wrong turn")
    }

    /// If you stall at a junction (haven't moved 5 m for 10 s while one is right
    /// in front of you), repeat its turn instruction.
    private func checkStalledAtJunction(coordinate: CLLocationCoordinate2D, time: Date) {
        guard let j = hudJunction, hudMeters <= 15,
              let index = junctions.firstIndex(where: { $0.routeDistance == j.routeDistance }) else {
            repeatAnchor = nil; repeatAnchorSince = nil; repeatJunctionIndex = nil
            return
        }
        if repeatJunctionIndex != index || repeatAnchor == nil {
            repeatAnchor = coordinate; repeatAnchorSince = time; repeatJunctionIndex = index
            return
        }
        let moved = CLLocation(from: repeatAnchor!).distance(from: CLLocation(from: coordinate))
        if moved > 5 {
            repeatAnchor = coordinate; repeatAnchorSince = time
        } else if let since = repeatAnchorSince, time.timeIntervalSince(since) >= 10 {
            repeatAnchorSince = time                  // don't spam; wait another 10 s
            lastAnnouncement = j.spoken
            voice.speak(j.spoken)
        }
    }

    /// Automatic stops: near the finish (after a real hike), or when we've
    /// clearly jumped into a car and forgot to end the hike.
    private func checkAutoStop(coordinate: CLLocationCoordinate2D, time: Date) {
        // Speed since the previous fix.
        if let prev = lastFixTime {
            let dt = time.timeIntervalSince(prev)
            if dt > 0, let last = breadcrumb.dropLast().last {
                let d = CLLocation(from: last).distance(from: CLLocation(from: coordinate))
                let speed = d / dt
                if speed > carSpeed {
                    if fastSince == nil { fastSince = prev }
                    if let s = fastSince, time.timeIntervalSince(s) >= carSustain {
                        autoStop(); return
                    }
                } else {
                    fastSince = nil
                }
            }
        }
        lastFixTime = time

        // Near the finish, but only after a genuine hike (start and end can be
        // metres apart on a loop, so don't fire in the first 20 minutes).
        if elapsed >= autoStopMinElapsed, let end = plannedCoords.last {
            let toEnd = CLLocation(from: coordinate).distance(from: CLLocation(from: end))
            if toEnd <= autoStopEndRadius { autoStop() }
        }
    }

    private func autoStop() {
        onAutoStop?()
        stop()
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
        let secs = Int(calcRemaining.rounded())
        timeLeftText = String(format: "%d:%02d", secs / 3600, (secs % 3600) / 60)

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

    /// Grade-adjusted time remaining to the finish, as h:mm — the "time left in
    /// hike" HUD value.
    @Published private(set) var timeLeftText: String = "—"

    /// Predicted clock time you'll pass a point `d` metres along the route
    /// (grade-adjusted). Nil if it's behind you or the hike isn't running.
    func arrivalClock(atRouteDistance d: Double) -> String? {
        guard let eta, phase == .active, d >= walkerRouteDistance else { return nil }
        let remaining = eta.expectedTime(toDistance: d) - eta.expectedTime(toDistance: walkerRouteDistance)
        guard remaining > 0 else { return nil }
        return clock.string(from: Date().addingTimeInterval(remaining))
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
