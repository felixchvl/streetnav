import Combine
import CoreLocation
import Foundation
import simd

/// The streets ridden right now, before the server knows: while the app is open on a bike ride, the streets still to
/// ride (red) that the rider goes along turn blue at once, counted as the server will count them (streets.py): sampled
/// every 10 m, within 12 m of a position, in runs of five samples at least (fewer is only crossing the street) unless
/// that is the whole part. Only positions at a bike's speed count, not a walk or a run. They are kept a day, long enough
/// for the ride to reach the server and its streets to come back from it.
@MainActor
final class StreetnavLiveStreets: NSObject, ObservableObject {
    static let shared = StreetnavLiveStreets()

    /// The parts ridden since, as GeoJSON for the maps (`k`: their road class, for their width), nil while there are none.
    @Published private(set) var ridden: String?

    private static let reachM = 12.0
    private static let stepM = 10.0
    private static let minSamples = 5
    private static let cellM = 25.0
    /// 12.6 km/h: faster than a run.
    private static let minSpeed = 3.5
    private static let maxAccuracy = 25.0
    /// Positions closer than this in space and time are joined, so that a sparse fix leaves no gap in a street.
    private static let joinM = 60.0
    private static let joinS: TimeInterval = 15
    private static let keep: TimeInterval = 24 * 3600

    private let manager = CLLocationManager()
    private var index: Index?
    /// Positions kept (latitude, longitude, time), the last day's.
    private var points: [[Double]] = []
    /// Ridden samples of each part, and the pieces they make.
    private var marked: [Int: Set<Int>] = [:]
    private var pieces: [Int: [[SIMD2<Double>]]] = [:]
    private var lastSave = Date.distantPast
    private var subscription: AnyCancellable?

    private var file: URL { URL.cachesDirectory.appending(path: "Streetnav/live-positions.json") }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        points = ((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([[Double]].self, from: $0) } ?? [])
            .filter { Date().timeIntervalSince1970 - $0[2] < Self.keep }
        // Indexed again whenever new streets come from the server: the ones it now knows are no longer red.
        subscription = StreetnavRideHistory.shared.$streets.removeDuplicates().sink { [weak self] streets in
            self?.use(streets)
        }
    }

    /// While the app is on screen (it may not follow the rider in the background).
    func start() {
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        save()
    }

    private func use(_ streets: String?) {
        guard let streets else { return }
        Task {
            let index = await Task.detached(priority: .utility) { Index(geojson: streets) }.value
            self.index = index
            marked = [:]
            pieces = [:]
            var previous: [Double]?
            for point in points {
                mark(point, after: previous)
                previous = point
            }
            publish()
        }
    }

    private func record(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maxAccuracy,
              location.speed >= Self.minSpeed, -location.timestamp.timeIntervalSinceNow < 10 else { return }
        let point = [location.coordinate.latitude, location.coordinate.longitude, location.timestamp.timeIntervalSince1970]
        let previous = points.last
        points.append(point)
        if mark(point, after: previous) { publish() }
        // Saved often: an app killed or crashing loses at most these few seconds.
        if Date().timeIntervalSince(lastSave) > 5 { save() }
    }

    /// Marks the samples near `point`, and along the way from `previous` when close enough; true when a piece changed.
    @discardableResult
    private func mark(_ point: [Double], after previous: [Double]?) -> Bool {
        guard let index else { return false }
        var positions = [index.project(latitude: point[0], longitude: point[1])]
        if let previous, point[2] - previous[2] <= Self.joinS {
            let from = index.project(latitude: previous[0], longitude: previous[1])
            let length = simd_distance(from, positions[0])
            if length <= Self.joinM, length > 5 {
                let steps = Int(length / 5)
                positions += (1..<steps).map { from + (positions[0] - from) * (Double($0) / Double(steps)) }
            }
        }
        var touched = Set<Int>()
        for position in positions {
            for (part, sample) in index.samples(near: position, within: Self.reachM) {
                if marked[part, default: []].insert(sample).inserted { touched.insert(part) }
            }
        }
        var changed = false
        for part in touched {
            let runs = Self.runs(marked[part] ?? [], of: index.parts[part].lonLat.count)
            let newPieces = runs.map { Array(index.parts[part].lonLat[$0]) }
            if newPieces.count != pieces[part]?.count || newPieces.map(\.count) != pieces[part]?.map(\.count) {
                pieces[part] = newPieces.isEmpty ? nil : newPieces
                changed = true
            }
        }
        return changed
    }

    /// Runs of consecutive ridden samples long enough to be a ride along the street, or the whole part.
    private static func runs(_ samples: Set<Int>, of count: Int) -> [ClosedRange<Int>] {
        if samples.count == count { return [0...(count - 1)] }
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var last = -2
        for sample in samples.sorted() {
            if sample != last + 1 {
                if let start, last - start + 1 >= minSamples { runs.append(start...last) }
                start = sample
            }
            last = sample
        }
        if let start, last - start + 1 >= minSamples { runs.append(start...last) }
        return runs
    }

    private func publish() {
        guard let index else { return }
        let features = pieces.flatMap { part, lines in
            lines.map { line in
                let coordinates = line.map { "[\(String(format: "%.6f", $0.x)),\(String(format: "%.6f", $0.y))]" }.joined(separator: ",")
                return #"{"type":"Feature","geometry":{"type":"LineString","coordinates":[\#(coordinates)]},"properties":{"r":1,"k":\#(index.parts[part].k)}}"#
            }
        }
        ridden = features.isEmpty ? nil : #"{"type":"FeatureCollection","features":[\#(features.joined(separator: ","))]}"#
    }

    private func save() {
        lastSave = Date()
        points.removeAll { Date().timeIntervalSince1970 - $0[2] >= Self.keep }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(points).write(to: file, options: .atomic)
    }

    /// The streets still to ride, sampled every 10 m in metres around Paris, the samples sorted by square of 25 m.
    struct Index: Sendable {
        struct Part: Sendable {
            let k: Int
            let lonLat: [SIMD2<Double>]
            let metres: [SIMD2<Double>]
        }

        private struct Entry: Sendable {
            let cell: Int64
            let part: Int32
            let sample: Int32
        }

        private static let latitude0 = 48.85
        private static let longitude0 = 2.35
        private static let metresPerDegreeLatitude = 111_132.0
        private static let metresPerDegreeLongitude = 111_320.0 * cos(48.85 * .pi / 180)

        let parts: [Part]
        private let entries: [Entry]

        init(geojson: String) {
            let features = (try? JSONDecoder().decode(Collection.self, from: Data(geojson.utf8)))?.features ?? []
            var parts: [Part] = []
            var entries: [Entry] = []
            for feature in features where feature.properties.r == 0 && feature.geometry.coordinates.count >= 2 {
                let lonLat = Self.sampled(feature.geometry.coordinates.map { SIMD2($0[0], $0[1]) })
                let metres = lonLat.map { Self.project(latitude: $0.y, longitude: $0.x) }
                let part = Int32(parts.count)
                for (sample, position) in metres.enumerated() {
                    entries.append(Entry(cell: Self.cell(position), part: part, sample: Int32(sample)))
                }
                parts.append(Part(k: feature.properties.k ?? 3, lonLat: lonLat, metres: metres))
            }
            self.parts = parts
            self.entries = entries.sorted { $0.cell < $1.cell }
        }

        func project(latitude: Double, longitude: Double) -> SIMD2<Double> {
            Self.project(latitude: latitude, longitude: longitude)
        }

        /// (part, sample) of the samples within `reach` of `position`.
        func samples(near position: SIMD2<Double>, within reach: Double) -> [(Int, Int)] {
            let x = Int64((position.x / StreetnavLiveStreets.cellM).rounded(.down))
            let y = Int64((position.y / StreetnavLiveStreets.cellM).rounded(.down))
            var found: [(Int, Int)] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    let cell = Self.key(x + Int64(dx), y + Int64(dy))
                    var i = lowerBound(cell)
                    while i < entries.count, entries[i].cell == cell {
                        let entry = entries[i]
                        if simd_distance(parts[Int(entry.part)].metres[Int(entry.sample)], position) <= reach {
                            found.append((Int(entry.part), Int(entry.sample)))
                        }
                        i += 1
                    }
                }
            }
            return found
        }

        private func lowerBound(_ cell: Int64) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle].cell < cell { low = middle + 1 } else { high = middle }
            }
            return low
        }

        private static func project(latitude: Double, longitude: Double) -> SIMD2<Double> {
            SIMD2((longitude - longitude0) * metresPerDegreeLongitude, (latitude - latitude0) * metresPerDegreeLatitude)
        }

        private static func cell(_ position: SIMD2<Double>) -> Int64 {
            key(Int64((position.x / StreetnavLiveStreets.cellM).rounded(.down)),
                Int64((position.y / StreetnavLiveStreets.cellM).rounded(.down)))
        }

        private static func key(_ x: Int64, _ y: Int64) -> Int64 { (x << 32) ^ (y & 0xFFFF_FFFF) }

        /// The line's points every 10 m along it, its ends included.
        private static func sampled(_ line: [SIMD2<Double>]) -> [SIMD2<Double>] {
            var samples = [line[0]]
            var carried = 0.0
            for (from, to) in zip(line, line.dropFirst()) {
                let a = project(latitude: from.y, longitude: from.x)
                let b = project(latitude: to.y, longitude: to.x)
                let length = simd_distance(a, b)
                var at = StreetnavLiveStreets.stepM - carried
                while at < length {
                    samples.append(from + (to - from) * (at / length))
                    at += StreetnavLiveStreets.stepM
                }
                carried = length - (at - StreetnavLiveStreets.stepM)
            }
            if let last = line.last, samples.last != last { samples.append(last) }
            return samples
        }

        private struct Collection: Decodable { let features: [Feature] }
        private struct Feature: Decodable {
            let geometry: Geometry
            let properties: Properties
        }
        private struct Properties: Decodable {
            let r: Int
            let k: Int?
        }
        /// A LineString's points; none for any other kind of geometry.
        private struct Geometry: Decodable {
            let coordinates: [[Double]]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                coordinates = (try? container.decode([[Double]].self, forKey: .coordinates)) ?? []
            }

            enum CodingKeys: String, CodingKey { case coordinates }
        }
    }
}

extension StreetnavLiveStreets: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations { self.record(location) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.start() }
    }
}
