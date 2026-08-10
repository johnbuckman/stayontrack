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
            .overlay(alignment: .topTrailing) { recenterButton }
            .overlay(alignment: .bottom) { floatingControls }
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
            .background(.blue.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
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
        Group {
            switch hike.phase {
            case .idle:     preStartControls
            case .active:   activeControls
            case .finished: finishedControls
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .environment(\.colorScheme, .dark)   // light text over the scrim
    }

    // MARK: Pre-start

    private var preStartControls: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.routeName).font(.headline).lineLimit(1)
                    Text("\(model.distanceKmText) • \(model.markers.count) markers")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }

            Toggle(isOn: $model.reversed) {
                Label("Reverse direction", systemImage: "arrow.left.arrow.right")
            }
            Toggle(isOn: $simulate) {
                Label("Simulate (drag to walk)", systemImage: "hand.draw")
            }

            tileStatus
            trailStatus
            elevationStatus

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
                    Label("Navigate to start", systemImage: "car.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.blue.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.blue, lineWidth: 2))
                        .foregroundStyle(.white)
                }
            }

            Button {
                guard let start = model.travelCoordinates.first else { return }
                following = true
                hike.start(points: model.travelPoints,
                           name: model.routeName,
                           startCoordinate: start,
                           intersections: model.intersections)
            } label: {
                Label("Start hike", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.travelCoordinates.isEmpty)
        }
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

            if simulate {
                Label("Drag the blue dot to walk the route.",
                      systemImage: "hand.point.up.left")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                hike.stop()
            } label: {
                Label("Stop hike", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
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
            HStack(spacing: 12) {
                if let url = hike.exportURL {
                    ShareLink(item: url) {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
                Button("Done") { hike.reset() }
                    .buttonStyle(.bordered)
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
                Text("\(count) trail junctions on route (voice + arrows)")
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
        }.frame(maxWidth: .infinity)
    }
}
