import CoreLocation
import Foundation
import SwiftUI

enum StreetExplorationStatus: String, CaseIterable, Identifiable {
    case traveled
    case untraveled
    case planned
    case completedDuringRide
    case uncertain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .traveled: "deja parcourue"
        case .untraveled: "a decouvrir"
        case .planned: "itineraire"
        case .completedDuringRide: "decouverte aujourd'hui"
        case .uncertain: "donnee incertaine"
        }
    }

    var color: Color {
        switch self {
        case .traveled: .blue
        case .untraveled: .red
        case .planned: .mint
        case .completedDuringRide: .green
        case .uncertain: .gray
        }
    }
}

struct ExplorationStreetSegment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let status: StreetExplorationStatus
    let coordinates: [CLLocationCoordinate2D]
    let lengthMeters: Int

    static func == (lhs: ExplorationStreetSegment, rhs: ExplorationStreetSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ExplorationArea: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let completion: Double
    let remainingKilometers: Double
    let missingStreetCount: Int
    let center: CLLocationCoordinate2D

    static func == (lhs: ExplorationArea, rhs: ExplorationArea) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SurfaceBreakdown: Hashable {
    let cycleway: Double
    let calmStreets: Double
    let sharedRoads: Double
}

enum RouteConfidence: String, CaseIterable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: "confiance elevee"
        case .medium: "a verifier"
        case .low: "incertain"
        }
    }
}

struct NavigationInstruction: Identifiable, Hashable {
    let id = UUID()
    let distanceText: String
    let maneuver: String
    let streetName: String
    let symbolName: String
    let spokenLabel: String
}

struct RouteAlternative: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let durationMinutes: Int
    let newRoadKilometers: Double
    let routeCoordinates: [CLLocationCoordinate2D]
}

struct StreetnavRoute: Identifiable {
    let id = UUID()
    let name: String
    let durationMinutes: Int
    let distanceKilometers: Double
    let newRoadKilometers: Double
    let traveledRoadKilometers: Double
    let estimatedProgressGain: Double
    let elevationGainMeters: Int
    let arrivalText: String
    let confidence: RouteConfidence
    let surface: SurfaceBreakdown
    let isLoop: Bool
    let returnsHome: Bool
    let coordinates: [CLLocationCoordinate2D]
    let instructions: [NavigationInstruction]
    let alternatives: [RouteAlternative]
}

struct RideProgress: Hashable {
    var remainingMinutes: Int
    var remainingKilometers: Double
    var completedNewRoadMeters: Int
    var routeProgress: Double
    var currentInstructionIndex: Int
}

struct RideSummary: Hashable {
    let durationMinutes: Int
    let distanceKilometers: Double
    let newRoadKilometers: Double
    let discoveryShare: Double
    let estimatedWandrerGain: Double
    let areaCompletionBefore: Double
    let areaCompletionAfter: Double
    let heartRateAverage: Int?
    let calories: Int?
    let stravaState: SyncState
}

enum SyncState: String, CaseIterable, Identifiable {
    case connected
    case disconnected
    case tokenExpired
    case syncing
    case updated
    case unavailable

    var id: String { rawValue }
}

enum DeviceConnectionState: String, CaseIterable, Identifiable {
    case ready
    case connecting
    case unavailable
    case actionRequired

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ready: "pret"
        case .connecting: "connexion"
        case .unavailable: "indisponible"
        case .actionRequired: "action requise"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .unavailable: "minus.circle.fill"
        case .actionRequired: "exclamationmark.circle.fill"
        }
    }
}

struct IntegrationStatus: Hashable {
    var stravaSync: SyncState
    var lastStravaSyncText: String
    var importedRideCount: Int
    var wandrerConnected: Bool
    var wandrerFreshnessText: String
    var missingNearbyStreets: Int
    var isOffline: Bool
}

struct BikeStatus: Hashable {
    var state: DeviceConnectionState
    var name: String
    var batteryPercent: Int
    var isLocked: Bool
    var connectionQuality: String
    var unlockAutomationAvailable: Bool
}

struct WatchStatus: Hashable {
    var state: DeviceConnectionState
    var name: String
    var workoutReady: Bool
    var heartRateAvailable: Bool
    var actionButtonReady: Bool
}

enum GPSQuality: String, CaseIterable, Identifiable {
    case precise
    case approximate
    case weak
    case denied

    var id: String { rawValue }
    var label: String {
        switch self {
        case .precise: "GPS precis"
        case .approximate: "position approximative"
        case .weak: "signal GPS faible"
        case .denied: "position refusee"
        }
    }
}

enum PrototypeFlowState: String, CaseIterable, Identifiable {
    case home
    case planner
    case routePreview
    case readiness
    case navigating
    case approachingNewStreet
    case completedNewStreet
    case rerouting
    case weakGPS
    case paused
    case arrived

    var id: String { rawValue }
}

enum PlannerPriority: String, CaseIterable, Identifiable {
    case maximizeNewRoads
    case balanced
    case protectedCycleways

    var id: String { rawValue }
    var label: String {
        switch self {
        case .maximizeNewRoads: "Maximiser les rues nouvelles"
        case .balanced: "Equilibre"
        case .protectedCycleways: "Pistes protegees"
        }
    }
}

struct StreetnavPrototypeTuning: Hashable {
    var routeLineWidth: Double = 8
    var overlayOpacity: Double = 0.88
    var mapPitch: Double = 54
    var mapZoom: Double = 15.4
    var springResponse: Double = 0.34
    var springDamping: Double = 0.82
    var transitionDuration: Double = 0.22
    var staggerDelay: Double = 0.06
    var simulateHaptics: Bool = true
    var simulateReducedMotion: Bool = false
}
