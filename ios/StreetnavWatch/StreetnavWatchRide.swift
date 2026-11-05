import CoreLocation
import HealthKit
import OSLog

/// A bike ride recorded by the Watch: a cycling workout with its heart rate, distance and GPS route, saved to Apple
/// Health as a new workout when it ends (Streetnav changes no other). As it starts, the session is mirrored to the
/// iPhone, which iOS wakes in the background to unlock the bike; the iPhone sends back where it is with the bike.
@MainActor
final class StreetnavWatchRide: NSObject, ObservableObject {
    static let shared = StreetnavWatchRide()

    enum Phase: Equatable {
        case idle, starting, riding, ending
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startDate: Date?
    @Published private(set) var heartRate: Double?
    @Published private(set) var distanceMeters: Double = 0
    /// The iPhone's news of the bike, nil until it answers.
    @Published private(set) var bike: StreetnavRideLink.Bike?

    private let store = HKHealthStore()
    private let location = CLLocationManager()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var route: HKWorkoutRouteBuilder?

    /// Positions worse than this are left out of the route.
    nonisolated private static let maxAccuracy = 30.0

    override private init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .fitness
    }

    var isRiding: Bool { phase == .riding || phase == .starting }

    /// Starts the ride, from the Action button, the app's button or the iPhone (`startWatchApp`). Nothing happens while
    /// one is under way.
    func start() async {
        guard session == nil, phase != .starting else { return }
        phase = .starting
        bike = nil
        do {
            try await store.requestAuthorization(toShare: Self.written, read: Self.read)
            location.requestWhenInUseAuthorization()
            let configuration = StreetnavRideLink.configuration
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            startDate = start
            phase = .riding
            location.startUpdatingLocation()
            await mirror(session)
        } catch {
            session?.end()
            reset()
            phase = .failed("La sortie n'a pas démarré : \(error.localizedDescription)")
        }
    }

    /// Ends the ride; the workout and its route are saved once the session has ended (`finish`).
    func end() {
        guard let session, phase == .riding else { return }
        phase = .ending
        location.stopUpdatingLocation()
        session.end()
    }

    /// The ride the system brings back after the app was stopped during it (`handleActiveWorkoutRecovery`).
    func recover() async {
        guard session == nil, let session = try? await store.recoverActiveWorkoutSession() else { return }
        let builder = session.associatedWorkoutBuilder()
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        // The route's earlier points are lost with the app; it goes on from here.
        route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        startDate = builder.startDate ?? session.startDate
        distanceMeters = builder.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
        phase = .riding
        location.startUpdatingLocation()
    }

    /// The iPhone, woken in the background, unlocks the bike; without it (out of reach, no Streetnav), the ride goes on.
    private func mirror(_ session: HKWorkoutSession) async {
        do {
            try await session.startMirroringToCompanionDevice()
            log.notice("Ride mirrored to the iPhone")
        } catch {
            log.error("No mirroring to the iPhone: \(error.localizedDescription)")
        }
    }

    private let log = Logger(subsystem: "com.felixchevalier.streetnav.watchkitapp", category: "ride")

    private func finish(at date: Date) async {
        guard let builder else { return reset() }
        do {
            try await builder.endCollection(at: date)
            if let workout = try await builder.finishWorkout() {
                _ = try? await route?.finishRoute(with: workout, metadata: nil)
            }
            reset()
        } catch {
            reset()
            phase = .failed("La sortie n'a pas été enregistrée : \(error.localizedDescription)")
        }
    }

    private func reset() {
        location.stopUpdatingLocation()
        session = nil
        builder = nil
        route = nil
        startDate = nil
        heartRate = nil
        distanceMeters = 0
        bike = nil
        phase = .idle
    }

    /// Written: the new workout and what makes it up, nothing else.
    private static let written: Set<HKSampleType> = [
        HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate),
        HKQuantityType(.distanceCycling), HKQuantityType(.activeEnergyBurned),
    ]

    private static let read: Set<HKObjectType> = [
        HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.distanceCycling),
        HKQuantityType(.activeEnergyBurned),
    ]
}

extension StreetnavWatchRide: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in await self.finish(at: date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.phase = .failed("La sortie s'est arrêtée : \(error.localizedDescription)") }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let messages = data.compactMap(StreetnavRideLink.decode)
        Task { @MainActor in
            if let last = messages.last { self.bike = last.bike }
        }
    }
}

extension StreetnavWatchRide: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRate = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?
            .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let distance = workoutBuilder.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter())
        Task { @MainActor in
            if let heartRate { self.heartRate = heartRate }
            if let distance { self.distanceMeters = distance }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension StreetnavWatchRide: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let kept = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= Self.maxAccuracy }
        guard kept.isEmpty == false else { return }
        Task { @MainActor in
            guard self.phase == .riding else { return }
            try? await self.route?.insertRouteData(kept)
        }
    }
}
