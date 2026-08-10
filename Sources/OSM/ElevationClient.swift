import Foundation
import CoreLocation

/// Fills in elevation for a route whose GPX has none, so the grade-adjusted
/// "Calculated ETA" and elevation-gain stats still work. Uses the free
/// Open-Meteo elevation API (Copernicus DEM, no key), batched 100 points per
/// request. Runs at import while online; results are baked into the route so
/// the hike itself stays offline.
enum ElevationClient {
    enum FetchError: Error { case badResponse, decode }

    private struct Response: Decodable { let elevation: [Double] }

    /// Returns one elevation (metres) per input coordinate, in order.
    static func fetch(_ coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(coords.count)
        for chunk in stride(from: 0, to: coords.count, by: 100).map({
            Array(coords[$0..<min($0 + 100, coords.count)])
        }) {
            result.append(contentsOf: try await fetchChunk(chunk))
        }
        return result
    }

    private static func fetchChunk(_ coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        let lats = coords.map { String(format: "%.6f", $0.latitude) }.joined(separator: ",")
        let lons = coords.map { String(format: "%.6f", $0.longitude) }.joined(separator: ",")
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: lats),
            URLQueryItem(name: "longitude", value: lons)
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(osmUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.badResponse }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.elevation.count == coords.count else { throw FetchError.decode }
        return decoded.elevation
    }
}
