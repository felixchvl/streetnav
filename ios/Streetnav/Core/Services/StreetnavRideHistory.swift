import Foundation

/// The rides kept on the Streetnav server, as the map and the panel show them: every bike ride's track (GET /tracks)
/// and the riding statistics (GET /stats).
///
/// Both are kept in the app's caches, so that the map shows the tracks at once and away from home, where the server
/// cannot be reached; the tracks are downloaded again only when the server says they changed (ETag).
@MainActor
final class StreetnavRideHistory: ObservableObject {
    static let shared = StreetnavRideHistory()

    /// GeoJSON FeatureCollection, one LineString per ride, as text for Mapbox (decoded once, not at every redraw).
    @Published private(set) var tracks: String?
    /// Streets around Paris cut into ridden (`r` = 1) and not ridden (`r` = 0) parts, GeoJSON (GET /streets).
    @Published private(set) var streets: String?
    @Published private(set) var stats: Stats?
    @Published private(set) var isOffline = false

    struct Stats: Codable, Equatable {
        struct Totals: Codable, Equatable {
            let rides: Int
            let km: Double
            let hours: Double
            let climbM: Int

            enum CodingKeys: String, CodingKey { case rides, km, hours, climbM = "climb_m" }
        }
        struct Longest: Codable, Equatable {
            let day: String
            let km: Double
        }
        struct Year: Codable, Equatable, Identifiable {
            let year: Int
            let rides: Int
            let km: Double
            var id: Int { year }
        }
        let total: Totals
        let thisYear: Totals
        let thisMonth: Totals
        let last30Days: Totals
        struct Streets: Codable, Equatable {
            let riddenKm: Double
            let totalKm: Double
            var share: Double { totalKm > 0 ? riddenKm / totalKm : 0 }

            enum CodingKeys: String, CodingKey { case riddenKm = "ridden_km", totalKm = "total_km" }
        }
        /// An arrondissement of Paris or a commune of the inner suburbs: its ring (0 for Paris, 1 for the communes
        /// along its edge…) and its streets (server zones.py).
        struct Zone: Codable, Equatable, Identifiable {
            let code: String
            let name: String
            let department: String
            let ring: Int?
            let riddenKm: Double
            let totalKm: Double
            var id: String { code }

            enum CodingKeys: String, CodingKey {
                case code, name, department, ring, riddenKm = "ridden_km", totalKm = "total_km"
            }
        }
        let longest: Longest?
        let lastRide: String?
        let byYear: [Year]
        let streets: Streets?
        /// Absent from servers older than the zones.
        let zones: [Zone]?

        enum CodingKeys: String, CodingKey {
            case total, longest
            case thisYear = "this_year", thisMonth = "this_month", last30Days = "last_30_days", lastRide = "last_ride"
            case byYear = "by_year", streets, zones
        }

        var lastRideDate: Date? {
            guard let lastRide else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: lastRide) ?? ISO8601DateFormatter().date(from: lastRide)
        }
    }

    private let folder: URL = {
        let url = URL.cachesDirectory.appending(path: "Streetnav", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private var tracksFile: URL { folder.appending(path: "tracks.geojson") }
    private var streetsFile: URL { folder.appending(path: "streets.geojson") }
    private var statsFile: URL { folder.appending(path: "stats.json") }
    private var etagKey: String { "streetnav.tracks.etag" }

    private init() {
        tracks = try? String(contentsOf: tracksFile, encoding: .utf8)
        streets = try? String(contentsOf: streetsFile, encoding: .utf8)
        stats = (try? Data(contentsOf: statsFile)).flatMap { try? JSONDecoder().decode(Stats.self, from: $0) }
    }

    /// Asks the server for what changed; keeps what is cached when it cannot be reached.
    func refresh() async {
        guard let baseURL = StreetnavServerSettings.baseURL, let token = StreetnavServerSettings.token else { return }
        do {
            var request = URLRequest(url: baseURL.appending(path: "tracks"), timeoutInterval: 30)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if tracks != nil, let etag = UserDefaults.standard.string(forKey: etagKey) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, response) = try await StreetnavServerAccess.session.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 200 {
                try data.write(to: tracksFile, options: .atomic)
                UserDefaults.standard.set(http?.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
                tracks = String(decoding: data, as: UTF8.self)
            }

            if let fresh = try await download("streets", token: token, baseURL: baseURL, cached: streets != nil, to: streetsFile) {
                streets = fresh
            }

            var statsRequest = URLRequest(url: baseURL.appending(path: "stats"), timeoutInterval: 30)
            statsRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (statsData, statsResponse) = try await StreetnavServerAccess.session.data(for: statsRequest)
            if (statsResponse as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(Stats.self, from: statsData) {
                try? statsData.write(to: statsFile, options: .atomic)
                stats = decoded
            }
            isOffline = false
        } catch {
            isOffline = true
        }
    }

    /// GET path with its last ETag; the new body (also written to `file`), or nil when it has not changed.
    private func download(_ path: String, token: String, baseURL: URL, cached: Bool, to file: URL) async throws -> String? {
        let etagKey = "streetnav.\(path).etag"
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if cached, let etag = UserDefaults.standard.string(forKey: etagKey) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await StreetnavServerAccess.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        try data.write(to: file, options: .atomic)
        UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
        return String(decoding: data, as: UTF8.self)
    }
}
