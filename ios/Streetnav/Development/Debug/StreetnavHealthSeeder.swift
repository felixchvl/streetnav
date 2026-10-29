#if targetEnvironment(simulator)
import CoreLocation
import HealthKit
import HealthKitUI
import SwiftUI

/// Simulator only: writes made-up workouts into the simulator's Health so the read-only sync can be tried there.
/// Device builds do not contain this code, so on the iPhone Streetnav never asks to write to Health.
struct StreetnavHealthSeederSection: View {
    @State private var message: String?
    @State private var asksWriteAccess = false

    var body: some View {
        Section {
            Button("Ajouter 3 entrainements fictifs") { asksWriteAccess.toggle() }
            .healthDataAccessRequest(store: StreetnavHealthSeeder.store, shareTypes: StreetnavHealthSeeder.shareTypes,
                                     trigger: asksWriteAccess) { result in
                Task { @MainActor in
                    switch result {
                    case .success: message = await StreetnavHealthSeeder.addSamples()
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            }
            Button("Supprimer le dernier entrainement fictif") {
                Task { message = await StreetnavHealthSeeder.deleteLatest() }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Simulateur")
        } footer: {
            Text("Visible seulement dans le simulateur : ne touche qu'aux entrainements crees ici.")
        }
    }
}

enum StreetnavHealthSeeder {
    static let store = HKHealthStore()
    static let shareTypes: Set<HKSampleType> = [.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate),
                                                HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceCycling),
                                                HKQuantityType(.distanceWalkingRunning)]
    // Along the Canal Saint-Martin, then back.
    private static let canal = [(48.8675, 2.3655), (48.8722, 2.3652), (48.8767, 2.3694), (48.8822, 2.3708),
                                (48.8868, 2.3734), (48.8822, 2.3708), (48.8722, 2.3652)]
    private static let loop = [(48.8713, 2.3800), (48.8746, 2.3841), (48.8781, 2.3812), (48.8760, 2.3765), (48.8713, 2.3800)]

    static func addSamples() async -> String {
        do {
            let now = Date()
            try await save(.cycling, start: now.addingTimeInterval(-3 * 3600), minutes: 35, distance: (6_400, .distanceCycling), route: canal)
            try await save(.running, start: now.addingTimeInterval(-26 * 3600), minutes: 28, distance: (4_900, .distanceWalkingRunning), route: loop)
            try await save(.traditionalStrengthTraining, start: now.addingTimeInterval(-50 * 3600), minutes: 45, distance: nil, route: nil)
            return "3 entrainements fictifs ajoutes."
        } catch {
            return error.localizedDescription
        }
    }

    static func deleteLatest() async -> String {
        do {
            let created = try await HKSampleQueryDescriptor(
                predicates: [.workout(HKQuery.predicateForObjects(from: HKSource.default()))],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1).result(for: store)
            guard let latest = created.first else { return "Aucun entrainement fictif." }
            try await store.delete(latest)
            return "Entrainement du \(latest.startDate.formatted(date: .abbreviated, time: .shortened)) supprime."
        } catch {
            return error.localizedDescription
        }
    }

    private static func save(_ type: HKWorkoutActivityType, start: Date, minutes: Double,
                             distance: (Double, HKQuantityTypeIdentifier)?, route: [(Double, Double)]?) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = type
        configuration.locationType = route == nil ? .indoor : .outdoor
        let end = start.addingTimeInterval(minutes * 60)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: start)

        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = [HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: minutes * 9),
                                                    start: start, end: end)]
        if let (metres, identifier) = distance {
            samples.append(HKQuantitySample(type: HKQuantityType(identifier), quantity: HKQuantity(unit: .meter(), doubleValue: metres),
                                            start: start, end: end))
        }
        for second in stride(from: 0.0, to: minutes * 60, by: 30) {
            let t = start.addingTimeInterval(second)
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRate),
                                            quantity: HKQuantity(unit: bpm, doubleValue: 125 + 25 * sin(second / 300)),
                                            start: t, end: t))
        }
        try await builder.addSamples(samples)
        try await builder.addMetadata([HKMetadataKeyIndoorWorkout: route == nil,
                                       HKMetadataKeyElevationAscended: HKQuantity(unit: .meter(), doubleValue: route == nil ? 0 : 24)])
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return }

        guard let route else { return }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(locations(along: route, from: start, to: end))
        try await routeBuilder.finishRoute(with: workout, metadata: nil)
    }

    /// One fix every 5 s, spread evenly along the waypoints.
    private static func locations(along waypoints: [(Double, Double)], from start: Date, to end: Date) -> [CLLocation] {
        let count = Int(end.timeIntervalSince(start) / 5)
        let legs = Double(waypoints.count - 1)
        return (0...count).map { i in
            let position = Double(i) / Double(count) * legs
            let leg = min(Int(position), waypoints.count - 2)
            let f = position - Double(leg)
            let (a, b) = (waypoints[leg], waypoints[leg + 1])
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: a.0 + (b.0 - a.0) * f, longitude: a.1 + (b.1 - a.1) * f),
                              altitude: 40 + 6 * sin(Double(i) / 20), horizontalAccuracy: 5, verticalAccuracy: 4,
                              timestamp: start.addingTimeInterval(Double(i) * 5))
        }
    }
}
#endif
