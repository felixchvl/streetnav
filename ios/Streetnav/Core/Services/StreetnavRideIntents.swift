import AppIntents
import HealthKit

/// One press of the iPhone's Action button (or Siri, or a control): Streetnav comes to the foreground, the bike unlocks
/// and the Watch starts the ride, which it mirrors back here.
struct StreetnavPartirIntent: AppIntent {
    static let title: LocalizedStringResource = "Partir à vélo"
    static let description = IntentDescription("Ouvre Streetnav, déverrouille le vélo et lance la sortie sur la montre.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // The bike at once, then the Watch, whose ride mirrored here waits for this same unlock instead of asking again.
        Task { _ = await StreetnavMirroredRide.shared.unlock() }
        try? await HKHealthStore().startWatchApp(toHandle: StreetnavRideLink.configuration)
        return .result()
    }
}

struct StreetnavShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StreetnavPartirIntent(),
                    phrases: ["Partir à vélo avec \(.applicationName)", "\(.applicationName), on y va"],
                    shortTitle: "Partir à vélo",
                    systemImageName: "bicycle")
    }
}
