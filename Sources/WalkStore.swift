import Foundation

/// One recorded walk, saved as a GPX file on disk with a little metadata.
struct SavedWalk: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var date: Date
    var distanceMeters: Double
    var elevationGain: Double
    var durationSec: Double
    var fileName: String

    var fileURL: URL { WalkStore.directory.appendingPathComponent(fileName) }

    var distanceText: String { String(format: "%.2f km", distanceMeters / 1000) }
    var climbText: String { String(format: "%.0f m climb", elevationGain) }
    var durationText: String {
        let s = Int(durationSec)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
    var dateText: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Persists completed walks (GPX files + an index) so they can be listed,
/// exported and deleted later.
@MainActor
final class WalkStore: ObservableObject {
    @Published private(set) var walks: [SavedWalk] = []

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Walks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([SavedWalk].self, from: data) else { return }
        walks = list.sorted { $0.date > $1.date }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(walks) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Save a recorded track as a new walk. Returns the saved walk.
    @discardableResult
    func save(track: [RecordedPoint], name: String,
              distance: Double, elevation: Double, duration: Double) -> SavedWalk {
        let id = UUID()
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safe) \(id.uuidString.prefix(6)).gpx"
        let gpx = GPXExporter.gpxString(track: track, name: name)
        try? gpx.data(using: .utf8)?
            .write(to: Self.directory.appendingPathComponent(fileName), options: .atomic)

        let walk = SavedWalk(id: id, name: name,
                             date: track.first?.time ?? Date(),
                             distanceMeters: distance, elevationGain: elevation,
                             durationSec: duration, fileName: fileName)
        walks.insert(walk, at: 0)
        persist()
        return walk
    }

    func delete(at offsets: IndexSet) {
        for i in offsets {
            try? FileManager.default.removeItem(at: walks[i].fileURL)
        }
        walks.remove(atOffsets: offsets)
        persist()
    }

    func delete(_ walk: SavedWalk) {
        try? FileManager.default.removeItem(at: walk.fileURL)
        walks.removeAll { $0.id == walk.id }
        persist()
    }
}
