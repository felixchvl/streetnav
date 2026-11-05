import HealthKit
import OSLog
import UIKit
import UserNotifications

/// A ride started on the Watch (its Action button), mirrored here: iOS wakes Streetnav in the background, which unlocks
/// the bike over Bluetooth, tells the Watch how it went and leaves a notification. iOS brings no app to the foreground
/// by itself: a tap on the notification opens Streetnav.
@MainActor
final class StreetnavMirroredRide: NSObject {
    static let shared = StreetnavMirroredRide()

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

    /// Set at every launch, before anything else: the Watch's ride may be what launched the app.
    func listen() {
        store.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in StreetnavMirroredRide.shared.began(session) }
        }
    }

    /// Asked once, on screen, so that the notification of a ride started on the Watch can show.
    func askForNotifications() {
        guard StreetnavVanMoofAccount.shared.isSignedIn else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private let log = Logger(subsystem: "com.felixchevalier.streetnav", category: "ride")

    private func began(_ session: HKWorkoutSession) {
        log.notice("Ride mirrored from the Watch, app \(UIApplication.shared.applicationState == .background ? "in the background" : "on screen")")
        self.session = session
        session.delegate = self
        Task { await unlockBike() }
    }

    private func unlockBike() async {
        await tell(StreetnavVanMoofAccount.shared.isSignedIn ? .unlocking : .noAccount)
        let news = await unlock()
        log.notice("Bike: \(news.rawValue)")
        await tell(news)
        notify(news)
    }

    /// The bike unlocked once for a ride, whether the Watch or the iPhone's own button asked first: both ask within
    /// seconds of each other, and the second waits for the first's answer.
    func unlock() async -> StreetnavRideLink.Bike {
        if let unlocking, Date().timeIntervalSince(unlocking.asked) < 120 { return await unlocking.task.value }
        let task = Task { () -> StreetnavRideLink.Bike in
            guard StreetnavVanMoofAccount.shared.isSignedIn else { return .noAccount }
            let bike = StreetnavVanMoofBike.shared
            let unlocked = await bike.unlock()
            // Let go, for the VanMoof app to reach it, unless Streetnav is on screen and shows it.
            if UIApplication.shared.applicationState == .background { bike.disconnect() }
            return unlocked ? .unlocked : .notConfirmed
        }
        unlocking = (Date(), task)
        return await task.value
    }

    private var unlocking: (asked: Date, task: Task<StreetnavRideLink.Bike, Never>)?

    private func tell(_ bike: StreetnavRideLink.Bike) async {
        try? await session?.sendToRemoteWorkoutSession(data: StreetnavRideLink.encode(.init(bike: bike)))
    }

    private func notify(_ bike: StreetnavRideLink.Bike) {
        let content = UNMutableNotificationContent()
        content.title = "Sortie lancée sur la montre"
        content.body = "\(bike.label). Touche pour ouvrir Streetnav."
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "streetnav.ride", content: content, trigger: nil))
    }
}

extension StreetnavMirroredRide: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in self.session = nil }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in self.session = nil }
    }
}
