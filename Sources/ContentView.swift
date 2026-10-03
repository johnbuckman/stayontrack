import SwiftUI
import UniformTypeIdentifiers
import CoreLocation
import UIKit

struct ContentView: View {
    @EnvironmentObject var model: RouteModel
    @StateObject private var hike = HikeSession()
    @StateObject private var location = LocationProvider()
    @Environment(\.openURL) private var openURL
    @State private var showingImporter = false
    // Simulate (drag-to-walk) defaults ON only on the Mac dev build; OFF on iOS.
    @State private var simulate: Bool = {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }()
    @State private var following = true         // auto-recenter on the walker

    // Two-tap compass. Tap 1 turns a rotated map back to north; tap 2 (already
    // north-up) switches to heading-up, where the map turns with the phone so
    // you can hold it in front of you and see which way to bear; tap 3 is off.
    @State private var headingUp = false
    @State private var mapHeading: Double = 0
    @State private var northResetToken = 0

    /// The junction HUD banner occupies the top-centre while hiking; the
    /// top-corner buttons (recenter/food, stop, calculating badge) drop below it
    /// by this much so nothing overlaps the banner.
    private var hudBannerVisible: Bool { hike.isActive && hike.hudJunction != nil }
    private let hudBannerDrop: CGFloat = 112

    @State private var showStopConfirm = false
    @State private var showLocationDenied = false
    @State private var showWalkList = false
    @State private var showFood = false
    @State private var showToilets = false
    @State private var pendingResume: HikeCheckpoint?     // crash-recovery offer
    @State private var checkedForResume = false

    private var gpxType: UTType { UTType(importedAs: "com.topografix.gpx") }

    var body: some View {
        Group {
            if model.hasRoute {
                loadedView
            } else {
                emptyState
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [gpxType, .xml],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                hike.reset()
                model.load(from: url)
            }
        }
        .alert("Couldn't load hike",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { offerResumeIfInterrupted() }
        .onOpenURL { handleOpenedGPX($0) }
        // When the OSM junctions for the current route finish loading (Overpass
        // is async), push them into an in-progress hike — the case that matters
        // is a new GPX opened mid-trail, whose turns aren't ready at start.
        .onChange(of: model.intersections.count) { _, _ in
            if hike.isActive { hike.updateJunctions(model.junctions) }
        }
        .alert("Resume hike?", isPresented: Binding(get: { pendingResume != nil },
                                                    set: { if !$0 { pendingResume = nil } })) {
            Button("Resume") { resumeInterruptedHike() }
            Button("Discard", role: .destructive) {
                HikeCheckpointStore.clear(); pendingResume = nil
            }
        } message: {
            if let cp = pendingResume {
                Text("“\(cp.routeName)” was interrupted after \(String(format: "%.2f km", cp.distanceWalked / 1000)). Pick up where you left off?")
            }
        }
    }

    /// On launch, if a hike was interrupted mid-walk, offer to resume it.
    private func offerResumeIfInterrupted() {
        hike.onAutoStop = { location.stop() }        // auto-stop should also drop GPS
        guard !checkedForResume else { return }
        checkedForResume = true
        guard hike.phase == .idle, let cp = HikeCheckpointStore.load() else { return }
        pendingResume = cp
    }

    /// Start guiding the currently-loaded route (the Start button, and also the
    /// auto-start when a new GPX arrives mid-hike). Wires live GPS unless we're
    /// in drag-to-walk simulation.
    private func beginFollowing() {
        guard let start = model.travelCoordinates.first else { return }
        following = true
        hike.start(points: model.travelPoints,
                   name: model.routeName,
                   startCoordinate: start,
                   intersections: model.intersections,
                   reversed: model.reversed)
        if !simulate {
            location.onLocation = { coord, elev, time in
                hike.ingest(coordinate: coord, elevation: elev, time: time)
            }
            location.start()   // real GPS + background updates
        }
    }

    /// A GPX opened (share sheet / Files / open-in). If a hike is already
    /// running, drop it and start following the new route instead of continuing
    /// to guide the old trail.
    private func handleOpenedGPX(_ url: URL) {
        let wasHiking = hike.isActive
        if wasHiking {
            hike.reset()
            location.stop()
        }
        model.load(from: url)
        // Auto-start on the new route so guidance continues seamlessly. Junctions
        // are the geometry set until Overpass finishes filling model.intersections
        // in the background (same tradeoff as any freshly-imported route).
        if wasHiking { beginFollowing() }
    }

    /// Load a saved walk's GPX as the current route, returning to the pre-start
    /// screen ready to hike it again.
    private func loadSavedWalk(_ url: URL) {
        hike.reset()
        location.stop()
        model.load(from: url)
    }

    private func resumeInterruptedHike() {
        guard let cp = pendingResume else { return }
        model.reversed = cp.reversed                 // rebuild travel points in the saved direction
        following = true
        hike.resume(points: model.travelPoints,
                    name: model.routeName,
                    intersections: model.intersections,
                    from: cp)
        if !simulate {
            location.onLocation = { coord, elev, time in
                hike.ingest(coordinate: coord, elevation: elev, time: time)
            }
            location.start()
        }
        pendingResume = nil
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(radius: 5)
            Text("Stay on Track").font(.largeTitle.bold())
            Text("Share or open a GPX hike to get started.")
                .foregroundStyle(.secondary)
            Button { showingImporter = true } label: {
                Label("Import GPX", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
        }.padding()
    }

    // MARK: Loaded state

    private var loadedView: some View {
        RouteMapView(coordinates: model.travelCoordinates,
                     markers: model.markers,
                     junctions: model.junctions,
                     restaurants: model.restaurants,
                     toilets: model.toilets,
                     walker: hike.walker,
                     breadcrumb: hike.breadcrumb,
                     simulating: simulate && hike.isActive,
                     onWalk: { coord in
                         hike.ingest(coordinate: coord, elevation: nil, time: Date())
                     },
                     autoFollow: hike.isActive && !simulate,
                     following: following,
                     onUserPan: { following = false },
                     elevations: model.travelPoints.map(\.elevation),
                     progressDistance: hike.isActive ? hike.routeProgress : 0,
                     walkerHeading: hike.isActive && !simulate ? location.heading : nil,
                     deviceHeading: location.heading,
                     headingUp: headingUp,
                     northResetToken: northResetToken,
                     onMapHeadingChange: { mapHeading = $0 },
                     mapStyle: model.mapStyle)
            .ignoresSafeArea()
            .overlay(alignment: .top) { junctionHUD }
            .overlay(alignment: .topLeading) { recenterButton }
            .overlay(alignment: .topTrailing) { stopIcon }
            .overlay(alignment: .topTrailing) { calculatingBadge }
            .overlay(alignment: .bottom) { floatingControls }
            .overlay { researchingOverlay }
            .alert("End this hike?", isPresented: $showStopConfirm) {
                Button("End hike", role: .destructive) { location.stop(); hike.stop() }
                Button("Keep hiking", role: .cancel) {}
            }
            .sheet(isPresented: $showWalkList) {
                WalkListView(store: hike.walkStore, onLoad: loadSavedWalk)
            }
            .sheet(isPresented: $showFood) {
                RestaurantListView(restaurants: model.travelRestaurants,
                                   etaIntoHike: { d in
                                       let s = model.predictedSeconds(toDistance: d)
                                       guard s > 0 else { return nil }
                                       let t = Int(s.rounded())
                                       return String(format: "%d:%02d", t / 3600, (t % 3600) / 60)
                                   })
            }
            .sheet(isPresented: $showToilets) {
                ToiletListView(toilets: model.travelToilets,
                               etaIntoHike: { d in
                                   let s = model.predictedSeconds(toDistance: d)
                                   guard s > 0 else { return nil }
                                   let t = Int(s.rounded())
                                   return String(format: "%d:%02d", t / 3600, (t % 3600) / 60)
                               })
            }
            .onChange(of: location.denied) { _, denied in
                if denied { showLocationDenied = true }
            }
            .alert("Location access needed", isPresented: $showLocationDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn on Location for Stay on Track in Settings so it can follow your hike — or use the Simulate button to walk the route by dragging.")
            }
            .alert("Couldn't find a route",
                   isPresented: Binding(get: { if case .failed = model.altState { return true } else { return false } },
                                        set: { if !$0 { model.altState = .idle } })) {
                Button("OK", role: .cancel) { model.altState = .idle }
            } message: {
                if case .failed(let msg) = model.altState { Text(msg) }
            }
    }

    /// Top-right badge shown while the OSM turn network is still being fetched:
    /// says it's calculating and shows the live elapsed timer.
    @ViewBuilder private var calculatingBadge: some View {
        if model.trailState == .loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(format: "Calculating turns… %.1fs", model.trailElapsed))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 2)
            .padding(8)
            .padding(.top, hudBannerVisible ? hudBannerDrop : 0)   // drop below the HUD banner
        }
    }

    /// Modal "thinking" popup while an alternative route is being computed.
    @ViewBuilder private var researchingOverlay: some View {
        if model.altState == .working {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Researching route…").font(.headline)
                    Text("Finding a walkable path between the start and finish.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(radius: 12)
            }
            .transition(.opacity)
        }
    }

    /// Stop control at the top-right, with a Pause/Resume button beneath it.
    @ViewBuilder private var stopIcon: some View {
        if hike.isActive {
            VStack(spacing: 4) {
                Button { showStopConfirm = true } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .shadow(radius: 2)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { hike.togglePause() } label: {
                    Image(systemName: hike.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, hike.isPaused ? .green : .orange)
                        .shadow(radius: 2)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hike.isPaused ? "Resume walk" : "Pause walk")
            }
            .padding(.trailing, 8)
            .padding(.top, hudBannerVisible ? hudBannerDrop : 2)   // drop below the HUD banner
        }
    }

    /// Big next-junction indicator across the top: maneuver arrow, "Keep left",
    /// and metres remaining. Appears ~300 m out, clears 50 m past the junction.
    @ViewBuilder private var junctionHUD: some View {
        if hike.isActive, let j = hike.hudJunction {
            HStack(spacing: 16) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 42, weight: .heavy))
                    .rotationEffect(.degrees(j.angle))   // relative maneuver arrow
                VStack(alignment: .leading, spacing: 2) {
                    Text(j.instruction).font(.title.bold())
                        .lineLimit(1).minimumScaleFactor(0.7)   // never wrap "Straight"/"Right"
                    Text("\(Int(hike.hudMeters)) m")
                        .font(.title2).monospacedDigit().opacity(0.9)
                }
                Spacer()
            }
            .padding(20)
            // Reverted to the previous full-width banner (the width*0.5 shrink
            // made short instructions wrap); corner buttons drop below it now.
            .padding(.horizontal, 12)
            .background(.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.white)
            .shadow(radius: 5)
            .padding(.top, 12)
        }
    }

    private var paceColor: Color {
        guard let p = hike.paceDeltaPercent else { return .primary }
        return p >= 0 ? .green : .orange
    }

    /// Shown when a real walk is in progress but the user has panned away.
    /// Two-tap compass, replacing MapKit's (which only appears once the map is
    /// already rotated). The needle always shows which way north is on screen;
    /// the label says the mode you're in.
    ///
    /// Tap 1 on a rotated map turns it back to north. Tap 2, with the map
    /// already north-up, switches to **heading-up**: the map turns with the
    /// phone, so you hold it in front of you and see at a glance whether the
    /// trail bears left or right. Tap 3 returns to north-up.
    ///
    /// Hardware without a magnetometer (the Mac Catalyst dev build) skips the
    /// heading-up step entirely — the button is then just "reset north".
    @ViewBuilder private var compassButton: some View {
        Button(action: tapCompass) {
            Label {
                Text(headingUp ? "Ahead" : "North")
            } icon: {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(-mapHeading))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(headingUp ? Color.green : Color(.systemGray), in: Capsule())
            .foregroundStyle(.white)
            .shadow(radius: 3)
        }
    }

    /// True once the map is turned appreciably off north.
    private var mapIsRotated: Bool {
        let d = abs(mapHeading.truncatingRemainder(dividingBy: 360))
        return min(d, 360 - d) > 1
    }

    private func tapCompass() {
        if headingUp {                          // heading-up → north-up
            headingUp = false
            location.stopHeading()
            northResetToken += 1
        } else if mapIsRotated || !location.headingAvailable {
            northResetToken += 1                // turn a rotated map back to north
        } else {                                // already north-up → heading-up
            headingUp = true
            location.startHeading()
        }
    }

    @ViewBuilder private var recenterButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.mapStyle = model.mapStyle == .topo ? .standard : .topo
            } label: {
                Label(model.mapStyle == .topo ? "Topo" : "Map",
                      systemImage: model.mapStyle == .topo ? "mountain.2.fill" : "map")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(model.mapStyle == .topo ? Color.green : Color(.systemGray),
                                in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            compassButton
            if hike.isActive && !simulate && !following {
                Button {
                    following = true
                } label: {
                    Label("Recenter", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.blue, in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            if !model.restaurants.isEmpty {
                Button { showFood = true } label: {
                    Label("\(model.restaurants.count)", systemImage: "fork.knife")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            if !model.toilets.isEmpty {
                Button { showToilets = true } label: {
                    Label("\(model.toilets.count)", systemImage: "toilet")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.teal, in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
        }
        .padding()
        .padding(.top, hudBannerVisible ? hudBannerDrop : 0)   // drop below the HUD banner
    }

    /// The bottom controls, floated over the map (no opaque panel). A soft
    /// gradient scrim + forced dark colours keep the text legible on the map.
    @ViewBuilder private var floatingControls: some View {
        switch hike.phase {
        case .idle:
            elevationPanel(progress: 0) { preStartControls }
        case .active:
            elevationPanel(progress: hike.routeProgress) { activeControls }
        case .finished:
            finishedControls
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                )
                .environment(\.colorScheme, .dark)
        }
    }

    /// The elevation profile filling the bottom, with the phase's controls
    /// drawn on top as black text with a white glow (legible, no dark panel).
    private func elevationPanel<Controls: View>(progress: Double,
                                                @ViewBuilder controls: () -> Controls) -> some View {
        ZStack(alignment: .bottom) {
            ElevationProfileView(profile: model.elevationProfile,
                                 progress: progress,
                                 total: model.routeTotalDistance,
                                 temperatures: temperatureProfile,
                                 sampleTimes: timeProfile)
                .frame(height: 360)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .bottom)   // chart touches the very bottom
                .allowsHitTesting(false)           // let drags pass through to the map
            controls()
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)          // force black text regardless of system theme
    }

    /// Forecast temperature at each elevation sample, resolved to the clock time
    /// you're predicted to be there (anchored to the real start once hiking, so
    /// it adjusts as the walk progresses). Empty until a forecast has loaded.
    private var temperatureProfile: [Double?] {
        guard !model.weather.isEmpty else { return [] }
        let departure = hike.startedAt ?? Date()
        return model.elevationProfile.map { sample in
            let when = departure.addingTimeInterval(model.predictedSeconds(toDistance: sample.distance))
            return model.temperature(at: when)
        }
    }

    /// Predicted clock time at each elevation sample (same departure anchor as
    /// `temperatureProfile`), for the per-hour temperature labels.
    private var timeProfile: [Date?] {
        guard !model.weather.isEmpty else { return [] }
        let departure = hike.startedAt ?? Date()
        return model.elevationProfile.map { sample in
            departure.addingTimeInterval(model.predictedSeconds(toDistance: sample.distance))
        }
    }

    // MARK: Pre-start

    private var preStartControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(model.distanceKmText).font(.headline)
                combinedStatus
                Spacer()
            }
            .legibleGlow()

            HStack(spacing: 14) {
                if let gain = model.elevationGainText {
                    Label(gain, systemImage: "arrow.up.right")
                }
                if let eta = model.estimatedDurationText {
                    Label("\(eta) est.", systemImage: "clock")
                }
                Spacer()
            }
            .font(.subheadline)
            .legibleGlow()

            HStack(spacing: 10) {
                Button { model.reversed.toggle() } label: {
                    Label("Reverse", systemImage: "arrow.left.arrow.right").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint((model.reversed ? Color.blue : Color.gray).opacity(0.7))
                .fixedSize()
                Button { simulate.toggle() } label: {
                    Label("Simulate", systemImage: "hand.draw").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint((simulate ? Color.blue : Color.gray).opacity(0.7))
                .fixedSize()
                Spacer()
                Button { showingImporter = true } label: {
                    Label("GPX", systemImage: "square.and.arrow.down").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gray.opacity(0.7))
                .fixedSize()
            }

            HStack(spacing: 10) {
                Menu {
                    Button { model.computeAlternative(mode: .shorter) } label: {
                        Label("Shorter route", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    Button { model.computeAlternative(mode: .longer) } label: {
                        Label("Longer / scenic route", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.altState == .working { ProgressView().controlSize(.small) }
                        Label(model.altState == .working ? "Finding route…" : "Routes",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gray.opacity(0.7))
                .disabled(model.altState == .working)
                .fixedSize()

                Button { showWalkList = true } label: {
                    Label("Previously", systemImage: "clock.arrow.circlepath").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gray.opacity(0.7))
                .fixedSize()
                Spacer()
            }

            elevationStatus.legibleGlow()

            HStack(spacing: 8) {
                if let start = model.travelCoordinates.first {
                    Menu {
                        Button { openURL(NavApps.appleMaps(start)) } label: {
                            Label("Apple Maps", systemImage: "map")
                        }
                        if let g = NavApps.googleMaps(start), NavApps.canOpen(g) {
                            Button { openURL(g) } label: { Label("Google Maps", systemImage: "map") }
                        }
                        if let w = NavApps.waze(start), NavApps.canOpen(w) {
                            Button { openURL(w) } label: { Label("Waze", systemImage: "map") }
                        }
                        ShareLink(item: NavApps.shareURL(start)) {
                            Label("Other apps… (Tesla, etc.)", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("Navigate", systemImage: "car.fill")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(Color.teal.opacity(0.7))
                }

                Button {
                    beginFollowing()
                } label: {
                    Label("Start", systemImage: "play.fill").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(Color.blue.opacity(0.7))
                .disabled(model.travelCoordinates.isEmpty)
            }
        }
    }

    /// Offline-map state + turn count on one line.
    @ViewBuilder private var combinedStatus: some View {
        HStack(spacing: 6) {
            if let p = model.tileProgress {
                Image(systemName: p.isComplete ? "airplane.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(p.isComplete ? .green : .secondary)
                Text(p.isComplete ? "offline ready" : "saving maps \(p.done)/\(p.total)")
            }
            switch model.trailState {
            case .ready(let c): Text("· \(c) turns")
            case .loading:      Text("· loading turns…")
            case .failed:       Text("· no turns")
            case .idle:         EmptyView()
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    // MARK: Active

    private var activeControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                stat(hike.isPaused ? "Time (paused)" : "Time", hike.elapsedText,
                     tint: hike.isPaused ? .orange : .primary)
                stat("Walked", hike.distanceWalkedText)
                stat("Climb", hike.elevationGainText)
                stat("Off-trail", hike.offTrackText,
                     tint: hike.isOffTrail ? .red : .secondary)
            }
            HStack(spacing: 0) {
                stat("Time left", hike.timeLeftText)
                stat("ETA (calc)", hike.etaCalcText)
                stat("ETA (pace)", hike.etaPaceText)
                stat("Pace vs calc", hike.paceDeltaText, tint: paceColor)
            }

        }
    }

    // MARK: Finished

    private var finishedControls: some View {
        VStack(spacing: 12) {
            Text("Hike complete").font(.headline)
            HStack(spacing: 0) {
                stat("Time", hike.elapsedText)
                stat("Walked", hike.distanceWalkedText)
                stat("Climb", hike.elevationGainText)
            }
            HStack(spacing: 8) {
                Button { showWalkList = true } label: {
                    Label("Export GPX", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button { hike.reset() } label: {
                    Text("Done").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
            }
        }
    }

    // MARK: Bits

    /// Pre-download status on the start page, written around the question John
    /// actually asks it: can I put the phone in airplane mode yet? It covers
    /// BOTH basemaps, since both are cached at import and finishing one of them
    /// is not the same as being safe to fly.
    @ViewBuilder private var tileStatus: some View {
        if let progress = model.tileProgress {
            HStack(spacing: 8) {
                if progress.isComplete {
                    Image(systemName: "airplane.circle.fill").foregroundStyle(.green)
                    Text("Maps saved — safe for airplane mode (\(progress.total) tiles)")
                        .font(.footnote.weight(.medium)).foregroundStyle(.green)
                } else {
                    ProgressView(value: progress.fraction).frame(width: 90)
                    Text("Saving maps for offline \(progress.done)/\(progress.total)"
                         + etaSuffix(model.tileEtaSeconds)
                         + " — stay online")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var trailStatus: some View {
        HStack(spacing: 8) {
            switch model.trailState {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading trail junctions… \(Int(model.trailElapsed))s")
                    .font(.footnote).foregroundStyle(.secondary)
            case .ready(let count):
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").foregroundStyle(.green)
                Text("\(count) turns")
                    .font(.footnote).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Trail junctions unavailable — no junction warnings")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func etaSuffix(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s > 0 else { return "" }
        if s < 60 { return " · ~\(Int(s.rounded()))s left" }
        return " · ~\(Int(s / 60))m \(Int(s.truncatingRemainder(dividingBy: 60)))s left"
    }

    @ViewBuilder private var elevationStatus: some View {
        HStack(spacing: 8) {
            switch model.elevationState {
            case .native:
                EmptyView()
            case .fetching:
                ProgressView().controlSize(.small)
                Text("Fetching elevation (DEM)…")
                    .font(.footnote).foregroundStyle(.secondary)
            case .filled:
                Image(systemName: "mountain.2.fill").foregroundStyle(.green)
                Text("Elevation added from DEM")
                    .font(.footnote).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Elevation unavailable — ETA uses flat pace")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .legibleGlow()
    }
}

extension View {
    /// Subtle white glow so dark text stays legible over the map/chart.
    func legibleGlow() -> some View { shadow(color: .white.opacity(0.7), radius: 1) }
}
