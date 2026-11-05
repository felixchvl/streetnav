import AppIntents

/// The Action button of the Watch Ultra (Réglages → Bouton Action → Exercice → Streetnav): one press starts the ride, and
/// with it the iPhone unlocks the bike. Also offered in Shortcuts and on the workout's Smart Stack.
struct StreetnavStartRideIntent: StartWorkoutIntent {
    static let title: LocalizedStringResource = "Partir à vélo"
    static let description = IntentDescription("Lance une sortie vélo sur la montre ; l'iPhone déverrouille le vélo.")

    @Parameter(title: "Sortie")
    var workoutStyle: StreetnavRideStyle

    static var suggestedWorkouts: [StreetnavStartRideIntent] { [StreetnavStartRideIntent(style: .bike)] }

    var displayRepresentation: DisplayRepresentation {
        StreetnavRideStyle.caseDisplayRepresentations[workoutStyle] ?? DisplayRepresentation(title: "Vélo")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await StreetnavWatchRide.shared.start()
        return .result()
    }
}

/// The one kind of ride Streetnav records.
enum StreetnavRideStyle: String, AppEnum {
    case bike

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sortie"
    static let caseDisplayRepresentations: [StreetnavRideStyle: DisplayRepresentation] = [
        .bike: DisplayRepresentation(title: "Vélo", image: .init(systemName: "bicycle")),
    ]
}
