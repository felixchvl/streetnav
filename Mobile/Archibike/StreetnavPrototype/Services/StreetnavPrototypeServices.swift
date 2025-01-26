import CoreLocation
import Foundation

protocol ActivitySyncService {
    func currentStatus() async -> IntegrationStatus
    func syncNow() async -> IntegrationStatus
}

protocol ExplorationDataService {
    func currentArea() async -> ExplorationArea
    func streetSegments() async -> [ExplorationStreetSegment]
    func refreshWandrerImport() async -> IntegrationStatus
}

protocol RoutePlanningService {
    func planRoute(durationMinutes: Int, priority: PlannerPriority, avoidCobblestones: Bool, preferProtectedCycleways: Bool) async throws -> StreetnavRoute
}

protocol WorkoutSessionService {
    func readiness() async -> WatchStatus
    func startCyclingWorkout() async -> Bool
}

protocol BikeConnectionService {
    func currentBikeStatus() async -> BikeStatus
}

protocol LocationService {
    func currentCoordinate() async -> CLLocationCoordinate2D?
    func gpsQuality() async -> GPSQuality
}

enum MockRoutePlanningError: LocalizedError {
    case noRoute
    case offline

    var errorDescription: String? {
        switch self {
        case .noRoute: "Aucun parcours coherent trouve pour cette duree."
        case .offline: "La carte locale n'est pas disponible hors ligne."
        }
    }
}

struct MockStravaActivityService: ActivitySyncService {
    var status = StreetnavMockData.integrations

    func currentStatus() async -> IntegrationStatus { status }

    func syncNow() async -> IntegrationStatus {
        try? await Task.sleep(nanoseconds: 350_000_000)
        var synced = status
        synced.stravaSync = .updated
        synced.lastStravaSyncText = "a l'instant"
        return synced
    }
}

struct MockWandrerExplorationService: ExplorationDataService {
    var area = StreetnavMockData.area
    var segments = StreetnavMockData.streets
    var integration = StreetnavMockData.integrations

    func currentArea() async -> ExplorationArea { area }
    func streetSegments() async -> [ExplorationStreetSegment] { segments }

    func refreshWandrerImport() async -> IntegrationStatus {
        try? await Task.sleep(nanoseconds: 450_000_000)
        var refreshed = integration
        refreshed.wandrerFreshnessText = "mis a jour a l'instant"
        return refreshed
    }
}

struct MockRoutePlanningService: RoutePlanningService {
    var shouldFail = false

    func planRoute(durationMinutes: Int, priority: PlannerPriority, avoidCobblestones: Bool, preferProtectedCycleways: Bool) async throws -> StreetnavRoute {
        try await Task.sleep(nanoseconds: 650_000_000)
        guard shouldFail == false else { throw MockRoutePlanningError.noRoute }

        let base = StreetnavMockData.route
        let adjustedNewRoads: Double = switch priority {
        case .maximizeNewRoads: 3.1
        case .balanced: 2.7
        case .protectedCycleways: 2.4
        }
        return StreetnavRoute(
            name: base.name,
            durationMinutes: durationMinutes,
            distanceKilometers: max(4.8, Double(durationMinutes) / 5.0),
            newRoadKilometers: adjustedNewRoads,
            traveledRoadKilometers: max(1.4, Double(durationMinutes) / 5.0 - adjustedNewRoads),
            estimatedProgressGain: priority == .maximizeNewRoads ? 1.9 : 1.5,
            elevationGainMeters: base.elevationGainMeters,
            arrivalText: base.arrivalText,
            confidence: base.confidence,
            surface: preferProtectedCycleways ? SurfaceBreakdown(cycleway: 0.82, calmStreets: 0.14, sharedRoads: 0.04) : base.surface,
            isLoop: base.isLoop,
            returnsHome: base.returnsHome,
            coordinates: base.coordinates,
            instructions: base.instructions,
            alternatives: base.alternatives
        )
    }
}

struct MockAppleWatchWorkoutService: WorkoutSessionService {
    var status = StreetnavMockData.watch

    func readiness() async -> WatchStatus { status }
    func startCyclingWorkout() async -> Bool { status.workoutReady }
}

struct MockVanMoofConnectionService: BikeConnectionService {
    var status = StreetnavMockData.bike
    func currentBikeStatus() async -> BikeStatus { status }
}

struct MockLocationService: LocationService {
    var coordinate: CLLocationCoordinate2D? = StreetnavMockData.parisCenter
    var quality: GPSQuality = .precise

    func currentCoordinate() async -> CLLocationCoordinate2D? { coordinate }
    func gpsQuality() async -> GPSQuality { quality }
}

@MainActor
final class StreetnavPrototypeViewModel: ObservableObject {
    @Published var flowState: PrototypeFlowState
    @Published var area: ExplorationArea
    @Published var route: StreetnavRoute
    @Published var selectedAlternativeID: UUID?
    @Published var rideProgress: RideProgress
    @Published var summary: RideSummary
    @Published var integrations: IntegrationStatus
    @Published var watch: WatchStatus
    @Published var bike: BikeStatus
    @Published var gpsQuality: GPSQuality
    @Published var streets: [ExplorationStreetSegment]
    @Published var isPlanningRoute = false
    @Published var routeErrorMessage: String?
    @Published var selectedDuration = 45
    @Published var plannerPriority: PlannerPriority = .balanced
    @Published var avoidCobblestones = true
    @Published var preferProtectedCycleways = true
    @Published var avoidDifficultIntersections = true
    @Published var minimizeRepeatedRoads = false
    @Published var destinationMode = false
    @Published var audioGuidanceEnabled = true
    @Published var showsCompletionToast = false
    @Published var tuning = StreetnavPrototypeTuning()

    private let activityService: ActivitySyncService
    private let explorationService: ExplorationDataService
    private let routeService: RoutePlanningService
    private let workoutService: WorkoutSessionService
    private let bikeService: BikeConnectionService
    private let locationService: LocationService

    init(
        flowState: PrototypeFlowState = .home,
        activityService: ActivitySyncService = MockStravaActivityService(),
        explorationService: ExplorationDataService = MockWandrerExplorationService(),
        routeService: RoutePlanningService = MockRoutePlanningService(),
        workoutService: WorkoutSessionService = MockAppleWatchWorkoutService(),
        bikeService: BikeConnectionService = MockVanMoofConnectionService(),
        locationService: LocationService = MockLocationService()
    ) {
        self.flowState = flowState
        self.activityService = activityService
        self.explorationService = explorationService
        self.routeService = routeService
        self.workoutService = workoutService
        self.bikeService = bikeService
        self.locationService = locationService
        area = StreetnavMockData.area
        route = StreetnavMockData.route
        rideProgress = StreetnavMockData.rideProgress
        summary = StreetnavMockData.summary
        integrations = StreetnavMockData.integrations
        watch = StreetnavMockData.watch
        bike = StreetnavMockData.bike
        gpsQuality = .precise
        streets = StreetnavMockData.streets
        selectedAlternativeID = StreetnavMockData.route.alternatives.first?.id
    }

    convenience init(edgeCase: StreetnavEdgeCase) {
        self.init(flowState: edgeCase.flowState)
        apply(edgeCase)
    }

    func load() async {
        async let loadedArea = explorationService.currentArea()
        async let loadedStreets = explorationService.streetSegments()
        async let loadedIntegrations = activityService.currentStatus()
        async let loadedWatch = workoutService.readiness()
        async let loadedBike = bikeService.currentBikeStatus()
        async let loadedGPS = locationService.gpsQuality()
        area = await loadedArea
        streets = await loadedStreets
        integrations = await loadedIntegrations
        watch = await loadedWatch
        bike = await loadedBike
        gpsQuality = await loadedGPS
    }

    func openPlanner() {
        flowState = .planner
    }

    func planRoute() {
        isPlanningRoute = true
        routeErrorMessage = nil
        Task {
            do {
                route = try await routeService.planRoute(
                    durationMinutes: selectedDuration,
                    priority: plannerPriority,
                    avoidCobblestones: avoidCobblestones,
                    preferProtectedCycleways: preferProtectedCycleways
                )
                selectedAlternativeID = route.alternatives.first?.id
                isPlanningRoute = false
                flowState = .routePreview
            } catch {
                isPlanningRoute = false
                routeErrorMessage = "Aucun parcours adapte pour ce reglage. Essaie 45 min ou un profil plus equilibre."
            }
        }
    }

    func selectAlternative(_ alternative: RouteAlternative) {
        selectedAlternativeID = alternative.id
        route = StreetnavRoute(
            name: alternative.title,
            durationMinutes: alternative.durationMinutes,
            distanceKilometers: route.distanceKilometers,
            newRoadKilometers: alternative.newRoadKilometers,
            traveledRoadKilometers: max(0, route.distanceKilometers - alternative.newRoadKilometers),
            estimatedProgressGain: route.estimatedProgressGain,
            elevationGainMeters: route.elevationGainMeters,
            arrivalText: route.arrivalText,
            confidence: route.confidence,
            surface: route.surface,
            isLoop: route.isLoop,
            returnsHome: route.returnsHome,
            coordinates: alternative.routeCoordinates,
            instructions: route.instructions,
            alternatives: route.alternatives
        )
    }

    func prepareRide() {
        flowState = .readiness
    }

    func startNavigation() {
        flowState = .navigating
    }

    func completeNewStreet() {
        rideProgress.completedNewRoadMeters += 320
        showsCompletionToast = true
        flowState = .completedNewStreet
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showsCompletionToast = false
            if flowState == .completedNewStreet { flowState = .navigating }
        }
    }

    func pauseRide() {
        flowState = .paused
    }

    func resumeRide() {
        flowState = .navigating
    }

    func finishRide() {
        flowState = .arrived
    }

    func apply(_ edgeCase: StreetnavEdgeCase) {
        switch edgeCase {
        case .normalHome:
            flowState = .home
        case .noWandrerImport:
            integrations = StreetnavMockData.noWandrerIntegration
            area = ExplorationArea(name: "Canal Saint-Martin", completion: 0, remainingKilometers: 0, missingStreetCount: 0, center: StreetnavMockData.parisCenter)
        case .stravaDisconnected:
            integrations.stravaSync = .disconnected
        case .stravaTokenExpired:
            integrations.stravaSync = .tokenExpired
        case .locationDenied:
            gpsQuality = .denied
        case .preciseLocationDisabled:
            gpsQuality = .approximate
        case .weakGPS:
            gpsQuality = .weak
            flowState = .weakGPS
        case .offline:
            integrations.isOffline = true
        case .mapDataLoading:
            streets = []
        case .wandrerUpdating:
            integrations.wandrerFreshnessText = "mise a jour en cours"
        case .noUntraveledNearby:
            area = ExplorationArea(name: "Bastille", completion: 1, remainingKilometers: 0, missingStreetCount: 0, center: StreetnavMockData.parisCenter)
            streets = streets.map { ExplorationStreetSegment(name: $0.name, status: .traveled, coordinates: $0.coordinates, lengthMeters: $0.lengthMeters) }
        case .routeCalculationFailed:
            routeErrorMessage = "Aucun parcours clair pour cette duree."
            flowState = .planner
        case .noRouteWithinDuration:
            selectedDuration = 30
            routeErrorMessage = "Aucune boucle utile en 30 min autour d'ici."
            flowState = .planner
        case .watchUnavailable:
            watch = StreetnavMockData.unavailableWatch
        case .vanMoofUnavailable:
            bike = StreetnavMockData.unavailableBike
        case .vanMoofLowBattery:
            bike = StreetnavMockData.lowBatteryBike
        case .veryLongStreetName:
            rideProgress.currentInstructionIndex = 0
            route = StreetnavRoute(name: route.name, durationMinutes: route.durationMinutes, distanceKilometers: route.distanceKilometers, newRoadKilometers: route.newRoadKilometers, traveledRoadKilometers: route.traveledRoadKilometers, estimatedProgressGain: route.estimatedProgressGain, elevationGainMeters: route.elevationGainMeters, arrivalText: route.arrivalText, confidence: route.confidence, surface: route.surface, isLoop: route.isLoop, returnsHome: route.returnsHome, coordinates: route.coordinates, instructions: [.init(distanceText: "Dans 80 m", maneuver: "Serre a gauche", streetName: "Avenue de la Republique et du General-Leclerc", symbolName: "arrow.turn.up.left", spokenLabel: "Dans 80 metres, serre a gauche")], alternatives: route.alternatives)
        case .largeType, .smallPhone, .largePhone, .lightMode, .darkMode, .reducedMotion:
            break
        case .activeRide:
            flowState = .navigating
        case .pausedRide:
            flowState = .paused
        case .rerouting:
            flowState = .rerouting
        case .arrivalSummary:
            flowState = .arrived
        case .completedNeighborhood:
            area = ExplorationArea(name: "Republique", completion: 1, remainingKilometers: 0, missingStreetCount: 0, center: StreetnavMockData.parisCenter)
        }
    }
}

enum StreetnavEdgeCase: String, CaseIterable, Identifiable {
    case normalHome
    case noWandrerImport
    case stravaDisconnected
    case stravaTokenExpired
    case locationDenied
    case preciseLocationDisabled
    case weakGPS
    case offline
    case mapDataLoading
    case wandrerUpdating
    case noUntraveledNearby
    case routeCalculationFailed
    case noRouteWithinDuration
    case watchUnavailable
    case vanMoofUnavailable
    case vanMoofLowBattery
    case veryLongStreetName
    case largeType
    case smallPhone
    case largePhone
    case lightMode
    case darkMode
    case reducedMotion
    case activeRide
    case pausedRide
    case rerouting
    case arrivalSummary
    case completedNeighborhood

    var id: String { rawValue }

    var flowState: PrototypeFlowState {
        switch self {
        case .activeRide: .navigating
        case .pausedRide: .paused
        case .rerouting: .rerouting
        case .arrivalSummary: .arrived
        default: .home
        }
    }
}
