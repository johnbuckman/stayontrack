import Foundation
import CoreLocation

/// A planned walk the user chose to keep for another day ("Save for later"
/// when a GPX arrives from another app).
struct LaterWalk: Identifiable, Codable, Equatable {
    var id: String { fileName }
    let fileName: String
    var name: String
    var added: Date
    var distanceMeters: Double
    var climbMeters: Double?
    var estimatedSeconds: Double?

    var fileURL: URL { SavedForLaterStore.directory.appendingPathComponent(fileName) }

    var summaryText: String {
        var parts = [String(format: "%.1f km", distanceMeters / 1000)]
        if let c = climbMeters { parts.append(String(format: "%.0f m climb", c)) }
        if let s = estimatedSeconds, s > 0 {
            let m = Int(s / 60)
            parts.append(String(format: "~%d:%02d", m / 60, m % 60))
        }
        return parts.joined(separator: " · ")
    }
    var addedText: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "Saved " + f.string(from: added)
    }
}

/// Walks saved for later. Each one is a plain GPX file in
/// Application Support/SavedForLater; the folder itself is the source of truth
/// and the index only caches each file's figures. So a GPX copied into the
/// folder from outside (e.g. pushed from the Mac with
/// `xcrun devicectl device copy to --domain-type appDataContainer`) shows up on
/// the next refresh, and a file removed from the folder disappears.
@MainActor
final class SavedForLaterStore: ObservableObject {
    @Published private(set) var walks: [LaterWalk] = []

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SavedForLater", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    init() { refresh() }

    /// Re-scan the folder: keep cached figures for files still there, work out
    /// figures for new files, drop entries whose file has gone.
    func refresh() {
        let cached: [String: LaterWalk] = {
            guard let data = try? Data(contentsOf: indexURL),
                  let list = try? JSONDecoder().decode([LaterWalk].self, from: data) else { return [:] }
            return Dictionary(list.map { ($0.fileName, $0) }, uniquingKeysWith: { a, _ in a })
        }()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory,
                        includingPropertiesForKeys: [.creationDateKey])) ?? []
        var list: [LaterWalk] = []
        for url in files where url.pathExtension.lowercased() == "gpx" {
            let name = url.lastPathComponent
            if let hit = cached[name] { list.append(hit); continue }
            let added = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if let walk = Self.describe(url: url, fileName: name, added: added) { list.append(walk) }
        }
        walks = list.sorted { $0.added > $1.added }
        persist()
    }

    /// Save a GPX for later. Returns the saved walk, or nil if it isn't a GPX
    /// we can read.
    @discardableResult
    func add(data: Data, suggestedName: String?) -> LaterWalk? {
        guard let route = try? GPXParser.parse(data: data) else { return nil }
        let title = route.name ?? suggestedName ?? "Walk"
        var fileName = Self.safeFileName(title) + ".gpx"
        var n = 2
        while FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent(fileName).path) {
            fileName = Self.safeFileName(title) + " (\(n)).gpx"; n += 1
        }
        let url = Self.directory.appendingPathComponent(fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil,
              let walk = Self.describe(route: route, fileName: fileName, added: Date()) else { return nil }
        walks.insert(walk, at: 0)
        persist()
        return walk
    }

    func delete(_ walk: LaterWalk) {
        try? FileManager.default.removeItem(at: walk.fileURL)
        walks.removeAll { $0.id == walk.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(walks) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func describe(url: URL, fileName: String, added: Date) -> LaterWalk? {
        guard let data = try? Data(contentsOf: url), let route = try? GPXParser.parse(data: data) else { return nil }
        return describe(route: route, fileName: fileName, added: added)
    }

    /// Distance, climb and walking-time estimate, worked out the same way as
    /// the start screen (snapped length isn't known yet, so raw GPX distance).
    private static func describe(route: GPXRoute, fileName: String, added: Date) -> LaterWalk? {
        guard route.points.count > 1 else { return nil }
        let cumulative = Geo.cumulativeDistances(route.coordinates)
        let climb: Double? = route.hasElevation
            ? ElevationSmoothing.climb(cumulative: cumulative, elevations: route.points.map(\.elevation)).up
            : nil
        let eta = route.hasElevation
            ? ETAEngine(travelPoints: route.points).calculatedRemaining(fromDistance: 0)
            : nil
        let name = route.name ?? (fileName as NSString).deletingPathExtension
        return LaterWalk(fileName: fileName, name: name, added: added,
                         distanceMeters: cumulative.last ?? 0, climbMeters: climb, estimatedSeconds: eta)
    }

    private static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Walk" : String(cleaned.prefix(80))
    }
}
