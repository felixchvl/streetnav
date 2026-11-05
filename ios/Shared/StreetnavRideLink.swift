import Foundation
import HealthKit

/// What the Watch and the iPhone share about a ride started on the Watch: its kind, and the news of the bike the iPhone
/// sends back over the mirrored workout session (`sendToRemoteWorkoutSession`).
enum StreetnavRideLink {
    /// A bike ride outdoors, as Apple's Workout app records one, so that the server takes it like the others.
    static var configuration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        return configuration
    }

    /// Where the iPhone is with the bike.
    enum Bike: String, Codable, Sendable {
        case unlocking, unlocked, notConfirmed, noAccount

        var label: String {
            switch self {
            case .unlocking: "Déverrouillage du vélo…"
            case .unlocked: "Vélo déverrouillé"
            case .notConfirmed: "Le vélo n'a pas répondu"
            case .noAccount: "Pas de compte VanMoof sur l'iPhone"
            }
        }
    }

    struct Message: Codable, Sendable {
        var bike: Bike
    }

    static func encode(_ message: Message) -> Data {
        (try? JSONEncoder().encode(message)) ?? Data()
    }

    static func decode(_ data: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: data)
    }
}
