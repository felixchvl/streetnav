import SwiftUI

enum StreetnavMotion {
    static func spring(_ tuning: StreetnavPrototypeTuning, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.01) : .spring(response: tuning.springResponse, dampingFraction: tuning.springDamping)
    }

    static func ease(_ tuning: StreetnavPrototypeTuning, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: tuning.transitionDuration)
    }

    enum Phase: String, CaseIterable, Identifiable {
        case plannerPresentation = "Presentation du planificateur"
        case routeResultAppearance = "Resultat d'itineraire"
        case navigationStart = "Depart navigation"
        case newStreetCompletion = "Nouvelle rue terminee"
        case arrivalSummary = "Resume d'arrivee"

        var id: String { rawValue }
    }
}
