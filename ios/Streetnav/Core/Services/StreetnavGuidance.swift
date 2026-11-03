import Combine
import CoreLocation
import MapboxDirections
import MapboxNavigationCore

/// Bike guidance to a place found by the search bar, with Mapbox's navigation engine: the cycling route, the progress
/// along it, the position snapped to the street and rerouting when the rider leaves it. Silent: no voice.
///
/// The engine is created on the first ride only, so that opening the app never starts a (billed) navigation session.
@MainActor
final class StreetnavGuidance: ObservableObject {
    static let shared = StreetnavGuidance()

    @Published private(set) var isActive = false
    @Published private(set) var routes: NavigationRoutes?
    @Published private(set) var instruction: VisualInstructionBanner?
    @Published private(set) var progress: RouteProgress?
    @Published private(set) var location: CLLocation?
    @Published private(set) var hasArrived = false
    @Published private(set) var isStarting = false
    @Published private(set) var failure: String?
    private(set) var destinationName = ""

    private var core: MapboxNavigation?
    private var cancellables = Set<AnyCancellable>()

    var routeRefreshing: AnyPublisher<RefreshingStatus, Never> {
        core?.navigation().routeRefreshing ?? Empty().eraseToAnyPublisher()
    }

    /// Guidance to `place`, through the silent waypoints `via` of the way chosen (a detour along streets still to ride).
    func start(to place: StreetnavPlace, from here: CLLocation?, via: [CLLocationCoordinate2D] = []) async {
        let core = engine()
        isStarting = true
        failure = nil
        defer { isStarting = false }
        let origin = here ?? CLLocation(latitude: StreetnavMockData.parisCenter.latitude, longitude: StreetnavMockData.parisCenter.longitude)
        var start = Waypoint(location: origin)
        if origin.course >= 0 {
            start.heading = origin.course
            start.headingAccuracy = 90
        }
        let passed = via.map { coordinate in
            var waypoint = Waypoint(coordinate: coordinate)
            waypoint.separatesLegs = false
            return waypoint
        }
        let options = NavigationRouteOptions(waypoints: [start] + passed + [Waypoint(coordinate: place.coordinate, name: place.name)],
                                             profileIdentifier: .cycling, locale: Locale(identifier: "fr_FR"),
                                             distanceUnit: .kilometer)
        do {
            let routes = try await core.routingProvider().calculateRoutes(options: options).value
            destinationName = place.name
            hasArrived = false
            self.routes = routes
            core.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
            isActive = true
        } catch {
            failure = "Itinéraire impossible : \(error.localizedDescription)"
        }
    }

    func stop() {
        core?.tripSession().setToIdle()
        isActive = false
        routes = nil
        instruction = nil
        progress = nil
        hasArrived = false
    }

    private func engine() -> MapboxNavigation {
        if let core { return core }
        #if DEBUG
        // Development: -simulateRide YES rides the route by itself, to try the guidance in the simulator.
        let source: LocationSource = UserDefaults.standard.bool(forKey: "simulateRide")
            ? .simulation(initialLocation: CLLocationManager().location) : .live
        #else
        let source: LocationSource = .live
        #endif
        let navigation = MapboxNavigationProvider(coreConfig: CoreConfig(locationSource: source, locale: Locale(identifier: "fr_FR")))
            .mapboxNavigation
        core = navigation

        navigation.navigation().bannerInstructions
            .map { $0.visualInstruction }
            .sink { [weak self] in self?.instruction = $0 }
            .store(in: &cancellables)
        navigation.navigation().routeProgress
            .map { $0?.routeProgress }
            .sink { [weak self] progress in
                guard let self else { return }
                self.progress = progress
                if let progress, progress.isFinalLeg, progress.currentLegProgress.userHasArrivedAtWaypoint { hasArrived = true }
            }
            .store(in: &cancellables)
        navigation.navigation().locationMatching
            .map { $0.enhancedLocation }
            .sink { [weak self] in self?.location = $0 }
            .store(in: &cancellables)
        // A new route after leaving the planned one.
        navigation.tripSession().navigationRoutes
            .sink { [weak self] routes in
                guard let self, let routes, isActive else { return }
                self.routes = routes
            }
            .store(in: &cancellables)
        return navigation
    }
}
