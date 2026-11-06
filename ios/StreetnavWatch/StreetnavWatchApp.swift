import HealthKit
import SwiftUI
import WatchKit

/// Streetnav on the Watch: one bike ride at a time, started from the Action button (`StreetnavStartRideIntent`), from the
/// app, or from the iPhone. Embedded in the iPhone app, from which the iPhone's Watch app installs it: an install of
/// the iPhone app may update it on the Watch too.
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
