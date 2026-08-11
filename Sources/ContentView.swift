import SwiftUI
import UniformTypeIdentifiers
import CoreLocation
import UIKit

struct ContentView: View {
    @EnvironmentObject var model: RouteModel
    @StateObject private var hike = HikeSession()
    @Environment(\.openURL) private var openURL
    @State private var showingImporter = false
    @State private var simulate = true          // dev default: drag-to-walk
    @State private var following = true         // auto-recenter on the walker
    @State private var showStopConfirm = false
    @State private var showWalkList = false

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
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.hiking")
                .font(.system(size: 64)).foregroundStyle(.secondary)
            Text("Stay on Track").font(.largeTitle.bold())
            Text("Share or open a GPX hike to get started.")
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Button { showingImporter = true } label: {
                    Label("Import GPX", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Button("Load sample hike") { model.loadSample() }
                    .buttonStyle(.bordered)
            }.padding(.horizontal, 40)
        }.padding()
    }

    // MARK: Loaded state

    private var loadedView: some View {
        RouteMapView(coordinates: model.travelCoordinates,
                     markers: model.markers,
                     junctions: model.junctions,
                     walker: hike.walker,
                     breadcrumb: hike.breadcrumb,
                     simulating: simulate && hike.isActive,
                     onWalk: { coord in
                         hike.ingest(coordinate: coord, elevation: nil, time: Date())
                     },
                     autoFollow: hike.isActive && !simulate,
                     following: following,
                     onUserPan: { following = false })
            .ignoresSafeArea()
            .overlay(alignment: .top) { junctionHUD }
            .overlay(alignment: .topLeading) { recenterButton }
            .overlay(alignment: .topTrailing) { stopIcon }
            .overlay(alignment: .bottom) { floatingControls }
            .alert("End this hike?", isPresented: $showStopConfirm) {
                Button("End hike", role: .destructive) { hike.stop() }
                Button("Keep hiking", role: .cancel) {}
            }
            .sheet(isPresented: $showWalkList) {
                WalkListView(store: hike.walkStore)
            }
    }

    /// Small stop control at the top-right.
    @ViewBuilder private var stopIcon: some View {
        if hike.isActive {
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
            .padding(.trailing, 8)
            .padding(.top, 2)
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
                    Text("\(Int(hike.hudMeters)) m")
                        .font(.title2).monospacedDigit().opacity(0.9)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.white)
            .shadow(radius: 5)
            .padding(.horizontal, 10)
            .padding(.top, 12)
        }
    }

    private var paceColor: Color {
        guard let p = hike.paceDeltaPercent else { return .primary }
        return p >= 0 ? .green : .orange
    }

    /// Shown when a real walk is in progress but the user has panned away.
    @ViewBuilder private var recenterButton: some View {
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
            .padding()
        }
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
                                 total: model.routeTotalDistance)
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

    // MARK: Pre-start

    private var preStartControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(model.distanceKmText).font(.headline)
                combinedStatus
                Spacer()
            }
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
                    guard let start = model.travelCoordinates.first else { return }
                    following = true
                    hike.start(points: model.travelPoints,
                               name: model.routeName,
                               startCoordinate: start,
                               intersections: model.intersections)
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
                Image(systemName: p.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(p.isComplete ? .green : .secondary)
                Text(p.isComplete ? "\(p.total) tiles" : "caching \(p.done)/\(p.total)")
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
                stat("Time", hike.elapsedText)
                stat("Walked", hike.distanceWalkedText)
                stat("Climb", hike.elevationGainText)
                stat("Off-trail", hike.offTrackText,
                     tint: hike.isOffTrail ? .red : .secondary)
            }
            HStack(spacing: 0) {
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

    @ViewBuilder private var tileStatus: some View {
        if let progress = model.tileProgress {
            HStack(spacing: 8) {
                if progress.isComplete {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Offline map ready (\(progress.total) tiles)")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: progress.fraction).frame(width: 90)
                    Text("Caching map \(progress.done)/\(progress.total)"
                         + etaSuffix(model.tileEtaSeconds))
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
