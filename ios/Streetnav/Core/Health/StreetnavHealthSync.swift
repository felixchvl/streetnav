import CoreLocation
import Foundation
import HealthKit
import Security
import UIKit

/// Where the Streetnav server lives: its address in the defaults, the API token in the keychain.
enum StreetnavServerSettings {
    private static let urlKey = "streetnav.server.url"
    private static let tokenService = "com.felixchevalier.streetnav.api-token"

    static var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: urlKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: urlKey) }
    }

    static var token: String? {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: tokenService,
                                        kSecReturnData as String: true]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: tokenService]
            SecItemDelete(query as CFDictionary)
            guard let newValue, newValue.isEmpty == false else { return }
            var item = query
            item[kSecValueData as String] = Data(newValue.utf8)
            // Readable once the iPhone has been unlocked after a restart, so a background sync can still send.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static var client: StreetnavServerClient? {
        guard let baseURL, let token else { return nil }
        return StreetnavServerClient(baseURL: baseURL, token: token)
    }
}

enum StreetnavServerError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Renseigne l'adresse du serveur et le jeton."
        case .http(let code, let body): "Le serveur a repondu \(code) : \(body.prefix(160))"
        }
    }

    /// The server refused this very request (bad data): retrying it would fail again.
    var isRefusal: Bool {
        if case .http(let code, _) = self { return (400..<500).contains(code) && [401, 403, 408, 429].contains(code) == false }
        return false
    }
}

/// The Streetnav server API (server/streetnav_server/api.py).
struct StreetnavServerClient {
    let baseURL: URL
    let token: String

    private struct Outcome: Decodable { let outcome: String }
    private struct Status: Decodable { let activities: Int }

    /// Sends a workout; returns how the server filed it: created, merged or updated.
    func push(_ workout: StreetnavWorkoutUpload) async throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try await send("POST", "activities", body: encoder.encode(workout))
        return try JSONDecoder().decode(Outcome.self, from: data).outcome
    }

    /// A copy deleted in Apple Health. Deleting a copy the server does not know succeeds too.
    func deleteCopy(source: String, externalID: String) async throws {
        _ = try await send("DELETE", "copies/\(source)/\(externalID)")
    }

    /// Number of activities in the registry, to check the address and the token.
    func activityCount() async throws -> Int {
        try JSONDecoder().decode(Status.self, from: await send("GET", "status")).activities
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw StreetnavServerError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }
}

/// One Apple Health workout, as POST /activities expects it.
struct StreetnavWorkoutUpload: Encodable {
    /// [longitude, latitude, altitude m or null, Unix seconds]
    struct TrackPoint: Encodable {
        let lon: Double
        let lat: Double
        let alt: Double?
        let t: Int

        func encode(to encoder: Encoder) throws {
            var row = encoder.unkeyedContainer()
            try row.encode(lon)
            try row.encode(lat)
            try row.encode(alt)
            try row.encode(t)
        }
    }

    /// [Unix seconds, bpm]
    struct HeartRate: Encodable {
        let t: Int
        let bpm: Int

        func encode(to encoder: Encoder) throws {
            var row = encoder.unkeyedContainer()
            try row.encode(t)
            try row.encode(bpm)
        }
    }

    let source = "healthkit"
    let externalID: String
    let startedAt: Date
    let endedAt: Date
    let sport: String
    let sportType: String
    let name: String
    let indoor: Bool?
    let distanceM: Double?
    let durationS: Double
    let movingS: Double
    let calories: Double?
    let avgHR: Double?
    let maxHR: Double?
    let elevationGainM: Double?
    let points: [TrackPoint]
    let heartRate: [HeartRate]
    let device: String?
    let raw: [String: String]

    enum CodingKeys: String, CodingKey {
        case source, sport, name, indoor, calories, points, device, raw
        case externalID = "external_id", startedAt = "started_at", endedAt = "ended_at", sportType = "sport_type"
        case distanceM = "distance_m", durationS = "duration_s", movingS = "moving_s", avgHR = "avg_hr", maxHR = "max_hr"
        case elevationGainM = "elevation_gain_m", heartRate = "heart_rate"
    }
}

/// How the registry files a HealthKit workout type: its sport, Strava's sport type, and the name HealthFit gave the
/// same workouts (in French), so that both copies of a workout read alike.
enum StreetnavWorkoutKind {
    static func describe(_ type: HKWorkoutActivityType, indoor: Bool?) -> (sport: String, sportType: String, name: String) {
        let place = indoor == true ? " (en salle)" : indoor == false ? " (plein air)" : ""
        switch type {
        case .cycling: return ("cycling", indoor == true ? "VirtualRide" : "Ride", "Vélo" + place)
        case .running: return ("running", "Run", "Course à pied" + place)
        case .walking: return ("walking", "Walk", "Marche" + place)
        case .hiking: return ("hiking", "Hike", "Randonnée")
        case .swimming: return ("swimming", "Swim", "Natation")
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining:
            return ("training", "WeightTraining", "Renforcement musculaire")
        case .highIntensityIntervalTraining: return ("training", "HighIntensityIntervalTraining", "HIIT")
        case .yoga: return ("training", "Yoga", "Yoga")
        case .elliptical: return ("training", "Elliptical", "Elliptique")
        case .stairClimbing, .stairs: return ("training", "StairStepper", "Escaliers")
        case .mixedCardio, .crossTraining: return ("training", "Workout", "Entraînement")
        case .rowing: return ("rowing", "Rowing", "Aviron")
        case .downhillSkiing: return ("skiing", "AlpineSki", "Ski alpin")
        case .crossCountrySkiing: return ("skiing", "NordicSki", "Ski de fond")
        case .snowboarding: return ("skiing", "Snowboard", "Snowboard")
        case .climbing: return ("other", "RockClimbing", "Escalade")
        case .soccer: return ("other", "Soccer", indoor == true ? "Football en salle" : "Football")
        case .rugby: return ("other", "Workout", "Rugby")
        case .golf: return ("other", "Golf", "Golf")
        default: return ("other", "Workout", "Autre")
        }
    }
}

/// Sends Apple Health workouts to the Streetnav server. It only reads Health: it never asks to write to it.
///
/// An anchored query remembers what was already sent: the first sync sends the whole history, later ones only the
/// workouts added or deleted since. The anchor moves on once the server has taken a whole batch, so nothing is lost
/// while the server cannot be reached. iOS wakes the app up when a new workout reaches Health (background delivery).
@MainActor
final class StreetnavHealthSync: ObservableObject {
    static let shared = StreetnavHealthSync()

    static let distanceTypes: [HKQuantityType] = {
        var ids: [HKQuantityTypeIdentifier] = [.distanceCycling, .distanceWalkingRunning, .distanceSwimming,
                                               .distanceDownhillSnowSports, .distanceWheelchair]
        if #available(iOS 18.0, *) {
            ids += [.distanceRowing, .distanceCrossCountrySkiing, .distancePaddleSports, .distanceSkatingSports]
        }
        return ids.map { HKQuantityType($0) }
    }()

    static var readTypes: Set<HKObjectType> {
        Set([HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate),
             HKQuantityType(.activeEnergyBurned)] + distanceTypes)
    }

    @Published private(set) var needsAuthorization: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var progress = ""
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var sentCount: Int
    @Published private(set) var deletedCount: Int
    @Published private(set) var refusedCount: Int

    let store = HKHealthStore()
    private let defaults = UserDefaults.standard
    private var observing = false
    private var syncAgain = false
    private static let batchSize = 25
    private static let routeWait: TimeInterval = 48 * 3600

    private enum Keys {
        static let requested = "streetnav.health.authorizationRequested"
        static let anchor = "streetnav.health.anchor"
        static let awaitingRoute = "streetnav.health.awaitingRoute"
        static let lastSync = "streetnav.health.lastSync"
        static let sent = "streetnav.health.sent"
        static let deleted = "streetnav.health.deleted"
        static let refused = "streetnav.health.refused"
    }

    private init() {
        needsAuthorization = defaults.bool(forKey: Keys.requested) == false
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date
        sentCount = defaults.integer(forKey: Keys.sent)
        deletedCount = defaults.integer(forKey: Keys.deleted)
        refusedCount = defaults.integer(forKey: Keys.refused)
    }

    private var anchor: HKQueryAnchor? {
        get {
            defaults.data(forKey: Keys.anchor).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) },
                         forKey: Keys.anchor)
        }
    }

    /// Recent outdoor workouts sent without a route (id -> end date). A route is saved just after its workout, and
    /// a Watch's route can reach the iPhone later still: such workouts are sent again once it is there.
    private var awaitingRoute: [String: Date] {
        get { defaults.dictionary(forKey: Keys.awaitingRoute) as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.awaitingRoute) }
    }

    /// The answer to the Health prompt, which the view shows with `healthDataAccessRequest`: a prompt requested from
    /// `HKHealthStore.requestAuthorization` never appears while a sheet is on screen.
    func authorizationAnswered(_ result: Result<Bool, Error>) async {
        switch result {
        case .success:
            defaults.set(true, forKey: Keys.requested)
            await refreshAuthorizationState()
            startObserving()
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    /// iOS never says whether reading was allowed, only whether the question was already asked (for instance not yet
    /// for a type added in a later version of the app).
    func refreshAuthorizationState() async {
        guard HKHealthStore.isHealthDataAvailable(),
              let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes),
              status != .unknown else { return }
        needsAuthorization = status == .shouldRequest
    }

    /// The server answered again: an earlier error no longer applies.
    func serverReachable() {
        lastError = nil
    }

    /// Also called at launch: iOS only wakes an app for new workouts if it registered when it started.
    func startObserving() {
        guard observing == false, defaults.bool(forKey: Keys.requested), HKHealthStore.isHealthDataAvailable() else { return }
        observing = true
        // Each runs once right away, then whenever workouts or routes change, even with the app in the background.
        for type in [HKObjectType.workoutType(), HKSeriesType.workoutRoute()] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                Task { @MainActor in
                    if error == nil { await self?.sync() }
                    completionHandler()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// Sends everything again on the next sync, e.g. after the server's database was rebuilt. Deletes nothing.
    func resendEverything() async {
        guard isSyncing == false else { return }
        anchor = nil
        await sync()
    }

    func sync() async {
        guard isSyncing == false else {
            syncAgain = true
            return
        }
        guard let client = StreetnavServerSettings.client else {
            lastError = StreetnavServerError.notConfigured.localizedDescription
            return
        }
        isSyncing = true
        lastError = nil
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "streetnav.health-sync")
        repeat {
            syncAgain = false
            do {
                try await sendChanges(with: client)
                lastSync = Date()
                defaults.set(lastSync, forKey: Keys.lastSync)
            } catch {
                lastError = error.localizedDescription
                break
            }
        } while syncAgain
        isSyncing = false
        progress = ""
        UIApplication.shared.endBackgroundTask(backgroundTask)
    }

    private func sendChanges(with client: StreetnavServerClient) async throws {
        var sent = 0
        while true {
            let batch = try await HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: anchor, limit: Self.batchSize)
                .result(for: store)
            if batch.addedSamples.isEmpty && batch.deletedObjects.isEmpty { break }
            for deleted in batch.deletedObjects {
                try await client.deleteCopy(source: "healthkit", externalID: deleted.uuid.uuidString)
                awaitingRoute[deleted.uuid.uuidString] = nil
                deletedCount += 1
            }
            for workout in batch.addedSamples {
                do {
                    let upload = try await upload(for: workout)
                    _ = try await client.push(upload)
                    sentCount += 1
                    if upload.points.isEmpty && upload.indoor != true && Date().timeIntervalSince(workout.endDate) < Self.routeWait {
                        awaitingRoute[upload.externalID] = workout.endDate
                    }
                } catch let error as StreetnavServerError where error.isRefusal {
                    // Kept out of the way so one bad workout cannot block the others forever.
                    refusedCount += 1
                    lastError = error.localizedDescription
                }
                sent += 1
                progress = "\(sent) entrainements envoyes"
            }
            anchor = batch.newAnchor
            defaults.set(sentCount, forKey: Keys.sent)
            defaults.set(deletedCount, forKey: Keys.deleted)
            defaults.set(refusedCount, forKey: Keys.refused)
        }
        try await sendLateRoutes(with: client)
    }

    private func sendLateRoutes(with client: StreetnavServerClient) async throws {
        for (id, ended) in awaitingRoute {
            guard Date().timeIntervalSince(ended) < Self.routeWait, let uuid = UUID(uuidString: id) else {
                awaitingRoute[id] = nil
                continue
            }
            let found = try await HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: uuid))],
                                                          sortDescriptors: []).result(for: store)
            guard let workout = found.first else {
                awaitingRoute[id] = nil
                continue
            }
            let upload = try await upload(for: workout)
            guard upload.points.isEmpty == false else { continue }
            _ = try await client.push(upload)
            awaitingRoute[id] = nil
        }
    }

    private func upload(for workout: HKWorkout) async throws -> StreetnavWorkoutUpload {
        let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool
        let kind = StreetnavWorkoutKind.describe(workout.workoutActivityType, indoor: indoor)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRateStatistics = workout.statistics(for: HKQuantityType(.heartRate))
        let distance = Self.distanceTypes.lazy
            .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            .first { $0 > 0 }
        let source = workout.sourceRevision
        var raw = ["activity_type": String(workout.workoutActivityType.rawValue),
                   "source_app": source.source.name,
                   "bundle_id": source.source.bundleIdentifier]
        raw["product_type"] = source.productType

        return StreetnavWorkoutUpload(
            externalID: workout.uuid.uuidString,
            startedAt: workout.startDate,
            endedAt: workout.endDate,
            sport: kind.sport,
            sportType: kind.sportType,
            name: kind.name,
            indoor: indoor,
            distanceM: distance,
            durationS: workout.endDate.timeIntervalSince(workout.startDate),
            movingS: workout.duration,
            calories: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            avgHR: heartRateStatistics?.averageQuantity()?.doubleValue(for: bpm),
            maxHR: heartRateStatistics?.maximumQuantity()?.doubleValue(for: bpm),
            elevationGainM: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            points: try await track(of: workout),
            heartRate: try await heartRate(during: workout),
            device: workout.device?.name ?? source.source.name,
            raw: raw)
    }

    private func track(of workout: HKWorkout) async throws -> [StreetnavWorkoutUpload.TrackPoint] {
        let routes = try await HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
        var points: [StreetnavWorkoutUpload.TrackPoint] = []
        for route in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                guard location.horizontalAccuracy >= 0 else { continue }
                points.append(.init(lon: location.coordinate.longitude, lat: location.coordinate.latitude,
                                    alt: location.verticalAccuracy >= 0 ? location.altitude : nil,
                                    t: Int(location.timestamp.timeIntervalSince1970)))
            }
        }
        return points
    }

    private func heartRate(during workout: HKWorkout) async throws -> [StreetnavWorkoutUpload.HeartRate] {
        let during = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
        let samples = try await HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: during)],
            sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return samples.map { .init(t: Int($0.startDate.timeIntervalSince1970), bpm: Int($0.quantity.doubleValue(for: bpm).rounded())) }
    }
}
