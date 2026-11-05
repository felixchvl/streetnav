import HealthKit
import SwiftUI
import WatchKit

/// Streetnav on the Watch: one bike ride at a time, started from the Action button (`StreetnavStartRideIntent`), from the
/// app, or from the iPhone. Not embedded in the iPhone app for now, so that installing that one never installs this one
/// on the Watch: it is built and installed on its own (scheme StreetnavWatch).
@main
struct StreetnavWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: StreetnavWatchDelegate

    var body: some Scene {
        WindowGroup {
            StreetnavWatchView()
        }
    }
}

final class StreetnavWatchDelegate: NSObject, WKApplicationDelegate {
    /// The iPhone's "Partir à vélo" (`HKHealthStore.startWatchApp`).
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in await StreetnavWatchRide.shared.start() }
    }

    /// A ride under way when the app was stopped.
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in await StreetnavWatchRide.shared.recover() }
    }
}
