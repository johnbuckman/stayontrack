import Foundation
import CoreLocation

/// One hourly forecast point.
struct WeatherHour: Codable, Equatable {
    let time: Date
    let tempC: Double
}

/// Fetches an hourly temperature forecast for the hike from Open-Meteo (free, no
/// key). Cached per-route-per-day so it works offline once imported.
enum WeatherClient {
    static func fetch(lat: Double, lon: Double) async -> [WeatherHour] {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", lat)),
            .init(name: "longitude", value: String(format: "%.4f", lon)),
            .init(name: "hourly", value: "temperature_2m"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "UTC")
        ]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        struct Payload: Decodable {
            struct Hourly: Decodable { let time: [Double]; let temperature_2m: [Double] }
            let hourly: Hourly
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return zip(p.hourly.time, p.hourly.temperature_2m).map {
            WeatherHour(time: Date(timeIntervalSince1970: $0), tempC: $1)
        }
    }
}

/// Per-route/day disk cache for the forecast.
enum WeatherCache {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeatherCache", isDirectory: true)
    }
    /// Key by rounded location + calendar day so a stale forecast expires.
    static func key(lat: Double, lon: Double, dayStamp: String) -> String {
        String(format: "%.3f_%.3f_%@", lat, lon, dayStamp)
    }
    static func load(_ key: String) -> [WeatherHour]? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WeatherHour].self, from: data)
    }
    static func save(_ key: String, _ hours: [WeatherHour]) {
        guard let data = try? JSONEncoder().encode(hours) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
