import CoreLocation
import Foundation

/// A bike ride as the server lists it (GET /activities?sport=cycling).
struct StreetnavRide: Decodable, Hashable, Identifiable {
    let id: Int
    let startedAt: Date
    let name: String?
    let distanceM: Double?
    let durationS: Double?
    let elevationGainM: Double?
    let calories: Double?
    let avgHr: Double?
    let hasTrack: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, calories
        case startedAt = "started_at", distanceM = "distance_m", durationS = "duration_s"
        case elevationGainM = "elevation_gain_m", avgHr = "avg_hr", hasTrack = "has_track"
    }

    /// Its name, or the time of day it started, as Fitness names a workout without one.
    var title: String {
        if let name, name.trimmingCharacters(in: .whitespaces).isEmpty == false { return name }
        switch Calendar.current.component(.hour, from: startedAt) {
        case 5..<12: return "Sortie du matin"
        case 12..<14: return "Sortie de midi"
        case 14..<18: return "Sortie de l'après-midi"
        case 18..<22: return "Sortie du soir"
        default: return "Sortie de nuit"
        }
    }
}

/// What GET /activities/{id} adds to the list: the track and the heart rate's peak.
struct StreetnavRideDetail: Decodable {
    let movingS: Double?
    let maxHr: Double?
    let track: StreetnavGeoLines?

    enum CodingKeys: String, CodingKey { case movingS = "moving_s", maxHr = "max_hr", track }
}

/// The streets one ride went along (GET /activities/{id}/streets, server map_data.py): its tronçons in the order it rode
/// them, the part ridden of each, and the ride's totals.
struct StreetnavRideStreets: Decodable {
    struct Feature: Decodable {
        struct Properties: Decodable {
            let osmID: Int?
            let name: String?
            /// It rode the tronçon all along.
            let complete: Bool
            /// It was the first ride to ride it all along.
            let new: Bool
            /// Complete passages over it, all rides.
            let p: Int

            enum CodingKeys: String, CodingKey { case osmID = "osm_id", name, complete, new, p }
        }

        let geometry: StreetnavGeoLines
        let properties: Properties
    }

    struct Summary: Decodable {
        let troncons: Int
        let complete: Int
        let new: Int
        let streets: Int
        let km: Double
        let newKm: Double

        enum CodingKeys: String, CodingKey { case troncons, complete, new, streets, km, newKm = "new_km" }
    }

    let features: [Feature]
    let summary: Summary

    /// A street of the ride: its tronçons with the same name (or the same OSM way when it has none), in the order it first
    /// came to it.
    struct Street: Identifiable {
        let id: String
        let name: String?
        var meters: Double
        /// One of its tronçons was ridden all along for the first time.
        var isNew: Bool
        /// Each tronçon ridden all along.
        var complete: Bool
        var passages: Int
        var lines: [[CLLocationCoordinate2D]]
    }

    var streets: [Street] {
        var order: [String] = []
        var byID: [String: Street] = [:]
        for feature in features {
            let properties = feature.properties
            let id = properties.name ?? properties.osmID.map { "osm:\($0)" } ?? "?"
            let meters = feature.geometry.meters
            if var street = byID[id] {
                street.meters += meters
                street.isNew = street.isNew || properties.new
                street.complete = street.complete && properties.complete
                street.passages = max(street.passages, properties.p)
                street.lines += feature.geometry.lines
                byID[id] = street
            } else {
                order.append(id)
                byID[id] = Street(id: id, name: properties.name, meters: meters, isNew: properties.new,
                                  complete: properties.complete, passages: properties.p, lines: feature.geometry.lines)
            }
        }
        return order.compactMap { byID[$0] }
    }
}

/// The lines of a GeoJSON LineString or MultiLineString, longitude and latitude only; anything else is empty.
struct StreetnavGeoLines: Decodable {
    let lines: [[CLLocationCoordinate2D]]

    private enum CodingKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        let points: (([Double]) -> CLLocationCoordinate2D?) = { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        switch type {
        case "LineString":
            lines = [(try container.decode([[Double]].self, forKey: .coordinates)).compactMap(points)]
        case "MultiLineString":
            lines = (try container.decode([[[Double]]].self, forKey: .coordinates)).map { $0.compactMap(points) }
        default:
            lines = []
        }
    }

    /// Their length along the ground, in metres.
    var meters: Double {
        lines.reduce(0) { total, line in
            zip(line, line.dropFirst()).reduce(total) { sum, pair in
                sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            }
        }
    }
}

/// The bike rides on the server, newest first, a hundred at a time; the first hundred kept in the caches so that the list
/// shows at once and away from home.
@MainActor
final class StreetnavRidesStore: ObservableObject {
    static let shared = StreetnavRidesStore()

    @Published private(set) var rides: [StreetnavRide] = []
    @Published private(set) var isLoading = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var isOffline = false

    private static let pageSize = 100
    private let cacheFile = URL.cachesDirectory.appending(path: "Streetnav/rides.json")

    private init() {
        rides = (try? Data(contentsOf: cacheFile)).flatMap { try? Self.decoder.decode([StreetnavRide].self, from: $0) } ?? []
    }

    /// The newest rides again.
    func refresh() async {
        #if DEBUG
        if Self.sample {
            rides = (try? Self.decoder.decode([StreetnavRide].self, from: Self.sampleRidesJSON())) ?? []
            reachedEnd = true
            return
        }
        #endif
        guard let client = StreetnavServerSettings.client, isLoading == false else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.send("GET", "activities", query: Self.query(until: nil))
            let page = try Self.decoder.decode([StreetnavRide].self, from: data)
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            rides = page
            reachedEnd = page.count < Self.pageSize
            isOffline = false
        } catch {
            isOffline = true
        }
    }

    /// The hundred before the oldest shown.
    func loadMore() async {
        guard let client = StreetnavServerSettings.client, isLoading == false, reachedEnd == false,
              let oldest = rides.last?.startedAt else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.send("GET", "activities", query: Self.query(until: oldest))
            let page = try Self.decoder.decode([StreetnavRide].self, from: data)
            let known = Set(rides.map(\.id))
            rides += page.filter { known.contains($0.id) == false }
            reachedEnd = page.count < Self.pageSize
        } catch {
            isOffline = true
        }
    }

    static func detail(of ride: StreetnavRide) async throws -> StreetnavRideDetail {
        #if DEBUG
        if sample { return try decoder.decode(StreetnavRideDetail.self, from: sampleDetailJSON(ride)) }
        #endif
        guard let client = StreetnavServerSettings.client else { throw URLError(.userAuthenticationRequired) }
        return try decoder.decode(StreetnavRideDetail.self, from: await client.send("GET", "activities/\(ride.id)"))
    }

    static func streets(of ride: StreetnavRide) async throws -> StreetnavRideStreets {
        #if DEBUG
        if sample { return try decoder.decode(StreetnavRideStreets.self, from: sampleStreetsJSON(ride)) }
        #endif
        guard let client = StreetnavServerSettings.client else { throw URLError(.userAuthenticationRequired) }
        return try decoder.decode(StreetnavRideStreets.self, from: await client.send("GET", "activities/\(ride.id)/streets"))
    }

    private static func query(until: Date?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "sport", value: "cycling"), URLQueryItem(name: "limit", value: "\(pageSize)")]
        if let until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            items.append(URLQueryItem(name: "until", value: formatter.string(from: until)))
        }
        return items
    }

    /// The server's dates, as Python writes them: microseconds and an offset (`2026-10-31T22:41:12.123456+00:00`).
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(text)"))
            }
            return date
        }
        return decoder
    }()

    #if DEBUG
    // Development: -sampleRides YES makes rides of the tracks in the caches (GET /tracks), written as the server writes
    // them, so that the screens and the decoding are tried without the server.
    static var sample: Bool { UserDefaults.standard.bool(forKey: "sampleRides") }

    private static func sampleTracks() -> [(day: String, km: Double, line: [[Double]])] {
        guard let text = StreetnavRideHistory.shared.tracks,
              let collection = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let features = collection["features"] as? [[String: Any]] else { return [] }
        return features.suffix(12).reversed().compactMap { feature in
            guard let properties = feature["properties"] as? [String: Any], let day = properties["day"] as? String,
                  let line = (feature["geometry"] as? [String: Any])?["coordinates"] as? [[Double]] else { return nil }
            return (day, properties["km"] as? Double ?? 0, line)
        }
    }

    private static func sampleRidesJSON() -> Data {
        let rides = sampleTracks().enumerated().map { index, track -> [String: Any] in
            ["id": index + 1, "started_at": "\(track.day)T\(String(format: "%02d", 7 + index % 14)):41:12.123456+00:00",
             "name": index % 3 == 0 ? NSNull() : "Boucle n° \(index + 1)", "distance_m": track.km * 1000,
             "duration_s": track.km / 18 * 3600, "elevation_gain_m": 40 + index * 7, "calories": 300 + index * 12,
             "avg_hr": index % 2 == 0 ? 132 + index : NSNull(), "has_track": true]
        }
        return (try? JSONSerialization.data(withJSONObject: rides)) ?? Data("[]".utf8)
    }

    private static func sampleLine(_ ride: StreetnavRide) -> [[Double]] {
        let tracks = sampleTracks()
        return tracks.indices.contains(ride.id - 1) ? tracks[ride.id - 1].line : []
    }

    private static func sampleDetailJSON(_ ride: StreetnavRide) -> Data {
        let detail: [String: Any] = ["moving_s": (ride.durationS ?? 0) * 0.9, "max_hr": 171,
                                     "track": ["type": "LineString", "coordinates": sampleLine(ride)]]
        return (try? JSONSerialization.data(withJSONObject: detail)) ?? Data("{}".utf8)
    }

    /// The track cut into eight streets, every third new, the fifth ridden in part.
    private static func sampleStreetsJSON(_ ride: StreetnavRide) -> Data {
        let line = sampleLine(ride)
        let names: [Any] = ["Rue de Charonne", "Boulevard Voltaire", "Avenue Parmentier", NSNull(), "Rue Oberkampf",
                            "Quai de Valmy", "Rue du Faubourg-du-Temple", "Avenue de la République"]
        let size = max(2, line.count / names.count)
        let features = stride(from: 0, to: max(0, line.count - 1), by: size).enumerated().map { index, start -> [String: Any] in
            let part = Array(line[start...min(line.count - 1, start + size)])
            return ["type": "Feature", "id": index,
                    "geometry": ["type": index == 1 ? "MultiLineString" : "LineString",
                                 "coordinates": index == 1 ? [part] as Any : part as Any],
                    "properties": ["osm_id": 1000 + index, "name": names[index % names.count], "k": 3,
                                   "complete": index != 4, "new": index % 3 == 0, "p": index % 3 == 0 ? 1 : 2 + index * 3,
                                   "m": 200 + index * 35]]
        }
        let body: [String: Any] = ["type": "FeatureCollection", "features": features,
                                   "summary": ["troncons": features.count, "complete": features.count - 1,
                                               "new": (features.count + 2) / 3, "streets": names.count,
                                               "km": (ride.distanceM ?? 0) / 1000, "new_km": 1.84]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }
    #endif

    static func parseDate(_ text: String) -> Date? {
        var main = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let after = text[text.index(after: dot)...]
            let digits = after.prefix { $0.isNumber }
            fraction = Double("0.\(digits)") ?? 0
            main = String(text[..<dot]) + after.dropFirst(digits.count)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: main)?.addingTimeInterval(fraction)
    }
}
