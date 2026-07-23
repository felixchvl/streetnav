import CoreLocation
import Foundation

enum StreetnavMockData {
    static let parisCenter = CLLocationCoordinate2D(latitude: 48.8637, longitude: 2.3708)

    static let area = ExplorationArea(
        name: "Canal Saint-Martin",
        completion: 0.68,
        remainingKilometers: 12.4,
        missingStreetCount: 38,
        center: parisCenter
    )

    static let noWandrerIntegration = IntegrationStatus(
        stravaSync: .connected,
        lastStravaSyncText: "il y a 6 min",
        importedRideCount: 184,
        wandrerConnected: false,
        wandrerFreshnessText: "aucun import local",
        missingNearbyStreets: 0,
        isOffline: false
    )

    static let integrations = IntegrationStatus(
        stravaSync: .connected,
        lastStravaSyncText: "il y a 6 min",
        importedRideCount: 184,
        wandrerConnected: true,
        wandrerFreshnessText: "mis a jour il y a 2 jours",
        missingNearbyStreets: 38,
        isOffline: false
    )

    static let watch = WatchStatus(
        state: .ready,
        name: "Apple Watch Ultra",
        workoutReady: true,
        heartRateAvailable: true,
        actionButtonReady: false
    )

    static let unavailableWatch = WatchStatus(
        state: .unavailable,
        name: "Apple Watch",
        workoutReady: false,
        heartRateAvailable: false,
        actionButtonReady: false
    )

    static let bike = BikeStatus(
        state: .ready,
        name: "VanMoof S6",
        batteryPercent: 76,
        isLocked: true,
        connectionQuality: "proche",
        unlockAutomationAvailable: false
    )

    static let lowBatteryBike = BikeStatus(
        state: .actionRequired,
        name: "VanMoof S6",
        batteryPercent: 12,
        isLocked: true,
        connectionQuality: "faible",
        unlockAutomationAvailable: false
    )

    static let unavailableBike = BikeStatus(
        state: .unavailable,
        name: "VanMoof S6",
        batteryPercent: 0,
        isLocked: true,
        connectionQuality: "hors portee",
        unlockAutomationAvailable: false
    )

    static let streets: [ExplorationStreetSegment] = [
        .init(name: "Quai de Jemmapes", status: .traveled, coordinates: [c(48.8722, 2.3655), c(48.8706, 2.3662), c(48.8687, 2.3670)], lengthMeters: 840),
        .init(name: "Rue de Charonne", status: .untraveled, coordinates: [c(48.8543, 2.3794), c(48.8558, 2.3839), c(48.8583, 2.3891)], lengthMeters: 1300),
        .init(name: "Avenue Parmentier", status: .planned, coordinates: [c(48.8656, 2.3760), c(48.8625, 2.3781), c(48.8596, 2.3803)], lengthMeters: 980),
        .init(name: "Boulevard Voltaire", status: .traveled, coordinates: [c(48.8579, 2.3667), c(48.8608, 2.3704), c(48.8638, 2.3742)], lengthMeters: 1180),
        .init(name: "Rue du Chemin-Vert", status: .untraveled, coordinates: [c(48.8595, 2.3722), c(48.8618, 2.3767), c(48.8632, 2.3818)], lengthMeters: 1120),
        .init(name: "Boulevard Richard-Lenoir", status: .completedDuringRide, coordinates: [c(48.8556, 2.3690), c(48.8601, 2.3711), c(48.8645, 2.3735)], lengthMeters: 1260),
        .init(name: "Rue Oberkampf", status: .uncertain, coordinates: [c(48.8644, 2.3745), c(48.8653, 2.3791), c(48.8660, 2.3839)], lengthMeters: 900),
        .init(name: "Avenue Philippe-Auguste", status: .untraveled, coordinates: [c(48.8585, 2.3920), c(48.8540, 2.3952), c(48.8506, 2.3982)], lengthMeters: 1420)
    ]

    static let route = StreetnavRoute(
        name: "Boucle Canal - Nation",
        durationMinutes: 42,
        distanceKilometers: 8.4,
        newRoadKilometers: 3.1,
        traveledRoadKilometers: 5.3,
        estimatedProgressGain: 1.9,
        elevationGainMeters: 54,
        arrivalText: "20:47",
        confidence: .high,
        surface: SurfaceBreakdown(cycleway: 0.72, calmStreets: 0.21, sharedRoads: 0.07),
        isLoop: true,
        returnsHome: true,
        coordinates: [c(48.8637, 2.3708), c(48.8658, 2.3740), c(48.8643, 2.3806), c(48.8598, 2.3845), c(48.8549, 2.3902), c(48.8482, 2.3959), c(48.8506, 2.3826), c(48.8557, 2.3698), c(48.8637, 2.3708)],
        instructions: [
            .init(distanceText: "Dans 120 m", maneuver: "Tourne a droite", streetName: "Rue du Chemin-Vert", symbolName: "arrow.turn.up.right", spokenLabel: "Dans 120 metres, tourne a droite rue du Chemin-Vert"),
            .init(distanceText: "Dans 420 m", maneuver: "Continue", streetName: "Avenue Parmentier", symbolName: "arrow.up", spokenLabel: "Continue sur Avenue Parmentier"),
            .init(distanceText: "Dans 1,1 km", maneuver: "Prends la piste", streetName: "Boulevard Voltaire", symbolName: "bicycle", spokenLabel: "Prends la piste cyclable boulevard Voltaire")
        ],
        alternatives: [
            .init(title: "Maximum de nouvelles rues", subtitle: "+3,1 km decouverts", durationMinutes: 42, newRoadKilometers: 3.1, routeCoordinates: [c(48.8637, 2.3708), c(48.8658, 2.3740), c(48.8643, 2.3806), c(48.8549, 2.3902), c(48.8482, 2.3959)]),
            .init(title: "Plus fluide", subtitle: "moins de carrefours difficiles", durationMinutes: 39, newRoadKilometers: 2.4, routeCoordinates: [c(48.8637, 2.3708), c(48.8611, 2.3715), c(48.8581, 2.3766), c(48.8532, 2.3860)]),
            .init(title: "Plus cyclable", subtitle: "82 % pistes ou voies calmes", durationMinutes: 45, newRoadKilometers: 2.8, routeCoordinates: [c(48.8637, 2.3708), c(48.8682, 2.3676), c(48.8708, 2.3758), c(48.8599, 2.3855)])
        ]
    )

    static let rideProgress = RideProgress(
        remainingMinutes: 31,
        remainingKilometers: 6.2,
        completedNewRoadMeters: 320,
        routeProgress: 0.28,
        currentInstructionIndex: 0
    )

    static let summary = RideSummary(
        durationMinutes: 41,
        distanceKilometers: 8.7,
        newRoadKilometers: 3.4,
        discoveryShare: 0.39,
        estimatedWandrerGain: 2.1,
        areaCompletionBefore: 0.68,
        areaCompletionAfter: 0.71,
        heartRateAverage: 136,
        calories: 286,
        stravaState: .syncing
    )

    static func c(_ latitude: CLLocationDegrees, _ longitude: CLLocationDegrees) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
