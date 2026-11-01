import CoreLocation
import MapKit
import MapboxMaps

/// A place found by the search bar, and how to get there by bike.
struct StreetnavPlace: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let symbol: String
    let mapItem: MKMapItem

    static func == (lhs: StreetnavPlace, rhs: StreetnavPlace) -> Bool { lhs.id == rhs.id }
}

struct StreetnavBikeRoute: Equatable {
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
    let durationSeconds: Double

    static func == (lhs: StreetnavBikeRoute, rhs: StreetnavBikeRoute) -> Bool {
        lhs.distanceMeters == rhs.distanceMeters && lhs.durationSeconds == rhs.durationSeconds
    }
}

/// Place search for the search bar: Apple's suggestions while typing (the best ranked around Paris in our tests, and
/// free), then the bike route to the chosen place from Mapbox Directions' cycling profile.
@MainActor
final class StreetnavPlaceSearch: NSObject, ObservableObject {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    /// True between a keystroke and Apple's answer, so that "no result" only shows once it is true.
    @Published private(set) var isLooking = false
    @Published private(set) var place: StreetnavPlace?
    @Published private(set) var route: StreetnavBikeRoute?
    @Published private(set) var routeFailed = false

    private let completer = MKLocalSearchCompleter()
    private let location = CLLocationManager()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        // Within riding distance only: no village called "Velo" in Greece.
        completer.regionPriority = .required
    }

    var here: CLLocationCoordinate2D { location.location?.coordinate ?? StreetnavMockData.parisCenter }
    var hereLocation: CLLocation? { location.location }

    func update(query: String) {
        // Ranked around the rider, like Maps.
        completer.region = MKCoordinateRegion(center: here, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        completer.queryFragment = query
        isLooking = query.isEmpty == false
        if query.isEmpty { suggestions = [] }
    }

    func choose(_ suggestion: MKLocalSearchCompletion) async {
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start().mapItems.first else { return }
        let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality]
            .compactMap { $0 }.joined(separator: " ")
        place = StreetnavPlace(name: item.name ?? suggestion.title, address: address.isEmpty ? suggestion.subtitle : address,
                               coordinate: item.placemark.coordinate, symbol: Self.symbol(for: item.pointOfInterestCategory),
                               mapItem: item)
        route = nil
        routeFailed = false
        await loadRoute()
    }

    func clear() {
        place = nil
        route = nil
        routeFailed = false
    }

    /// Bike directions in Maps until Streetnav guides the ride itself.
    func openInMaps() {
        place?.mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeCycling])
    }

    var distanceFromHere: CLLocationDistance? {
        guard let place, let here = location.location else { return nil }
        return here.distance(from: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude))
    }

    private func loadRoute() async {
        guard let place else { return }
        let from = here
        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/cycling/"
            + "\(from.longitude),\(from.latitude);\(place.coordinate.longitude),\(place.coordinate.latitude)")!
        components.queryItems = [
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "language", value: "fr"),
            URLQueryItem(name: "access_token", value: MapboxOptions.accessToken),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let response = try JSONDecoder().decode(Directions.self, from: data)
            guard self.place == place, let first = response.routes.first else {
                routeFailed = self.place == place
                return
            }
            route = StreetnavBikeRoute(coordinates: first.geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) },
                                       distanceMeters: first.distance, durationSeconds: first.duration)
        } catch {
            if self.place == place { routeFailed = true }
        }
    }

    private struct Directions: Decodable {
        struct Route: Decodable {
            struct Geometry: Decodable { let coordinates: [[Double]] }
            let geometry: Geometry
            let distance: Double
            let duration: Double
        }
        let routes: [Route]
    }

    private static func symbol(for category: MKPointOfInterestCategory?) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .bakery: "birthday.cake.fill"
        case .nightlife, .brewery, .winery: "wineglass.fill"
        case .store, .foodMarket: "bag.fill"
        case .publicTransport: "tram.fill"
        case .park, .nationalPark: "leaf.fill"
        case .museum: "building.columns.fill"
        case .hospital, .pharmacy: "cross.fill"
        case .fitnessCenter: "figure.run"
        default: "mappin"
        }
    }
}

extension StreetnavPlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // The region only ranks places: towns of the same name abroad still come up. Keep the rider's country.
        let country = Locale.current.localizedString(forRegionCode: Locale.current.region?.identifier ?? "FR") ?? "France"
        let results = completer.results.filter { $0.subtitle.isEmpty || $0.subtitle.hasSuffix(country) }
        Task { @MainActor in
            self.suggestions = Array(results.prefix(8))
            self.isLooking = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
            self.isLooking = false
        }
    }
}
