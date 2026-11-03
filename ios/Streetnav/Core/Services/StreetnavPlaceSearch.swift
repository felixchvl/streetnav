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
    /// From Apple, when it knows the place: Maps' « Appeler » and « Site web » buttons.
    var phone: String? = nil
    var website: URL? = nil

    static func == (lhs: StreetnavPlace, rhs: StreetnavPlace) -> Bool { lhs.id == rhs.id }
}

/// One way there by bike: the most direct, or one going out of its way along streets still to ride.
struct StreetnavBikeRoute: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case direct
        case discovery
        case wideDiscovery

        var title: String {
            switch self {
            case .direct: "Direct"
            case .discovery: "Découverte"
            case .wideDiscovery: "Grande découverte"
            }
        }
    }

    let kind: Kind
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
    let durationSeconds: Double
    /// The silent waypoints it goes through, for the guidance to ride the same way.
    let via: [CLLocationCoordinate2D]
    /// Metres along streets still to ride (StreetnavLiveStreets), nil before the streets are known.
    let newMeters: Double?

    var id: Kind { kind }

    static func == (lhs: StreetnavBikeRoute, rhs: StreetnavBikeRoute) -> Bool {
        lhs.kind == rhs.kind && lhs.distanceMeters == rhs.distanceMeters && lhs.durationSeconds == rhs.durationSeconds
    }
}

/// A line of the search list, from Google or from Apple.
struct StreetnavSuggestion: Identifiable {
    enum Source {
        case google(placeID: String)
        case apple(MKLocalSearchCompletion)
    }

    let id: String
    let title: String
    let subtitle: String
    let source: Source
}

/// Place search for the search bar, then the bike routes to the chosen place from Mapbox Directions' cycling profile:
/// the most direct one, and up to two going out of their way along streets still to ride (StreetnavLiveStreets.detours,
/// as silent waypoints), each with its metres of new streets; a detour that brings none is left out.
///
/// With a Google key (`GOOGLE_PLACES_API_KEY` in the git-ignored `Config/Secrets.xcconfig`), suggestions come from
/// Google Places (New). Google's terms for Europe only allow a place's latitude, longitude and id next to a map that is
/// not Google's: Streetnav keeps just those, and the name and address shown on the map come from Apple at that point.
/// Without a key, Apple's suggestions are used.
@MainActor
final class StreetnavPlaceSearch: NSObject, ObservableObject {
    @Published private(set) var suggestions: [StreetnavSuggestion] = []
    /// True between a keystroke and the answer, so that "no result" only shows once it is true.
    @Published private(set) var isLooking = false
    @Published private(set) var problem: String?
    @Published private(set) var place: StreetnavPlace?
    /// The ways there, the most direct first.
    @Published private(set) var routes: [StreetnavBikeRoute] = []
    @Published var selected: StreetnavBikeRoute.Kind = .direct
    @Published private(set) var routeFailed = false

    /// The way chosen among `routes`.
    var route: StreetnavBikeRoute? { routes.first { $0.kind == selected } ?? routes.first }

    private let completer = MKLocalSearchCompleter()
    private let location = CLLocationManager()
    private let googleKey: String? = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GooglePlacesAPIKey") as? String,
              key.isEmpty == false, key.hasPrefix("$(") == false else { return nil }
        return key
    }()
    /// One Google session per search, from the first keystroke to the chosen place (billed as such).
    private var sessionToken: String?
    private var pending: Task<Void, Never>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        // Within riding distance only: no village called "Velo" in Greece.
        completer.regionPriority = .required
    }

    var usesGoogle: Bool { googleKey != nil }
    var here: CLLocationCoordinate2D { location.location?.coordinate ?? StreetnavMockData.parisCenter }
    var hereLocation: CLLocation? { location.location }

    func update(query: String) {
        isLooking = query.isEmpty == false
        problem = nil
        if query.isEmpty { suggestions = [] }
        guard googleKey != nil else {
            // Ranked around the rider, like Maps.
            completer.region = MKCoordinateRegion(center: here, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
            completer.queryFragment = query
            return
        }
        pending?.cancel()
        guard query.isEmpty == false else { return }
        // A short pause between keystrokes before asking Google, which bills each request.
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false, let self else { return }
            await self.askGoogle(query)
        }
    }

    func choose(_ suggestion: StreetnavSuggestion) async {
        switch suggestion.source {
        case .google(let placeID):
            guard let coordinate = await googleCoordinate(of: placeID) else { return }
            place = await applePlace(at: coordinate, named: suggestion.title)
        case .apple(let completion):
            guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first else { return }
            place = Self.place(from: item, fallbackName: completion.title, fallbackAddress: completion.subtitle)
        }
        routes = []
        selected = .direct
        routeFailed = false
        await loadRoutes()
    }

    /// A point held on the map, a building or not, as a place to ride to: its address from Apple, then the ways there.
    func choose(pointAt coordinate: CLLocationCoordinate2D, building: Bool) async {
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude,
                                                                                   longitude: coordinate.longitude)).first
        let street = [placemark?.subThoroughfare, placemark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let town = [placemark?.postalCode, placemark?.locality].compactMap { $0 }.joined(separator: " ")
        place = StreetnavPlace(name: street.isEmpty ? (building ? "Bâtiment" : "Point choisi") : street, address: town,
                               coordinate: coordinate, symbol: building ? "building.2.fill" : "mappin")
        routes = []
        selected = .direct
        routeFailed = false
        await loadRoutes()
    }

    func clear() {
        place = nil
        routes = []
        selected = .direct
        routeFailed = false
    }

    var distanceFromHere: CLLocationDistance? {
        guard let place, let here = location.location else { return nil }
        return here.distance(from: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude))
    }

    // MARK: Google Places (New)

    private func askGoogle(_ query: String) async {
        let token = sessionToken ?? UUID().uuidString
        sessionToken = token
        let center = ["latitude": here.latitude, "longitude": here.longitude]
        let body: [String: Any] = [
            "input": query, "sessionToken": token, "languageCode": "fr", "regionCode": "fr", "includedRegionCodes": ["fr"],
            // Restricted, not just biased: within 30 km of the rider, where a bike goes.
            "locationRestriction": ["circle": ["center": center, "radius": 30_000.0]], "origin": center,
        ]
        guard var request = googleRequest("https://places.googleapis.com/v1/places:autocomplete") else { return }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard Task.isCancelled == false else { return }
            try Self.check(response)
            let answer = try JSONDecoder().decode(Autocomplete.self, from: data)
            suggestions = (answer.suggestions ?? []).compactMap(\.placePrediction).prefix(8).map {
                StreetnavSuggestion(id: $0.placeId, title: $0.structuredFormat?.mainText.text ?? $0.text.text,
                                    subtitle: $0.structuredFormat?.secondaryText?.text ?? "", source: .google(placeID: $0.placeId))
            }
        } catch {
            suggestions = []
            problem = (error as? GoogleFailure)?.message ?? "Recherche Google indisponible."
        }
        isLooking = false
    }

    /// The place's location only, which also closes the billing session.
    private func googleCoordinate(of placeID: String) async -> CLLocationCoordinate2D? {
        var components = URLComponents(string: "https://places.googleapis.com/v1/places/\(placeID)")!
        if let sessionToken { components.queryItems = [URLQueryItem(name: "sessionToken", value: sessionToken)] }
        sessionToken = nil
        guard let url = components.url, var request = googleRequest(url.absoluteString) else { return nil }
        request.setValue("location", forHTTPHeaderField: "X-Goog-FieldMask")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response)
            let details = try JSONDecoder().decode(Details.self, from: data)
            return CLLocationCoordinate2D(latitude: details.location.latitude, longitude: details.location.longitude)
        } catch {
            problem = (error as? GoogleFailure)?.message ?? "Lieu Google introuvable."
            return nil
        }
    }

    private func googleRequest(_ url: String) -> URLRequest? {
        guard let googleKey, let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(googleKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // The key is restricted to this app.
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return
        case 400, 401, 403: throw GoogleFailure(message: "Google refuse la clé : vérifie Places API (New), la facturation et la restriction à l'app.")
        case 429: throw GoogleFailure(message: "Quota Google atteint pour aujourd'hui.")
        default: throw GoogleFailure(message: "Google a répondu \(status).")
        }
    }

    private struct GoogleFailure: Error { let message: String }

    private struct Autocomplete: Decodable {
        struct Suggestion: Decodable { let placePrediction: Prediction? }
        struct Prediction: Decodable {
            struct Text: Decodable { let text: String }
            struct Format: Decodable {
                let mainText: Text
                let secondaryText: Text?
            }
            let placeId: String
            let text: Text
            let structuredFormat: Format?
        }
        let suggestions: [Suggestion]?
    }

    private struct Details: Decodable {
        struct Location: Decodable {
            let latitude: Double
            let longitude: Double
        }
        let location: Location
    }

    // MARK: Apple

    /// What Apple knows at that point: the place itself if it has the same name nearby, otherwise its address.
    private func applePlace(at coordinate: CLLocationCoordinate2D, named name: String) async -> StreetnavPlace {
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
        if let items = try? await MKLocalSearch(request: request).start().mapItems,
           let item = items.min(by: { $0.placemark.location?.distance(from: point) ?? .infinity < $1.placemark.location?.distance(from: point) ?? .infinity }),
           let distance = item.placemark.location?.distance(from: point), distance < 80 {
            return Self.place(from: item, fallbackName: name, fallbackAddress: "", at: coordinate)
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(point).first
        let street = [placemark?.subThoroughfare, placemark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return StreetnavPlace(name: street.isEmpty ? "Lieu choisi" : street, address: placemark?.locality ?? "",
                              coordinate: coordinate, symbol: "mappin")
    }

    private static func place(from item: MKMapItem, fallbackName: String, fallbackAddress: String,
                              at coordinate: CLLocationCoordinate2D? = nil) -> StreetnavPlace {
        let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality]
            .compactMap { $0 }.joined(separator: " ")
        return StreetnavPlace(name: item.name ?? fallbackName, address: address.isEmpty ? fallbackAddress : address,
                              coordinate: coordinate ?? item.placemark.coordinate, symbol: symbol(for: item.pointOfInterestCategory),
                              phone: item.phoneNumber, website: item.url)
    }

    // MARK: Route

    /// How far from the direct way each detour looks for streets still to ride, and in how many stretches of it.
    private static let detours: [(kind: StreetnavBikeRoute.Kind, corridor: Double, count: Int)] =
        [(.discovery, 300, 2), (.wideDiscovery, 700, 4)]

    private func loadRoutes() async {
        guard let place else { return }
        let from = here
        guard let direct = await bikeRoute(.direct, from: from, via: [], to: place.coordinate) else {
            if self.place == place { routeFailed = true }
            return
        }
        guard self.place == place else { return }
        routes = [direct]
        let live = StreetnavLiveStreets.shared
        for detour in Self.detours {
            let via = live.detours(along: direct.coordinates, corridor: detour.corridor, count: detour.count)
            guard via.isEmpty == false, let route = await bikeRoute(detour.kind, from: from, via: via, to: place.coordinate),
                  self.place == place else { continue }
            // Worth showing only for new streets the routes before it do not ride, and when not the same way again.
            let best = routes.compactMap(\.newMeters).max() ?? 0
            let same = routes.contains { abs($0.distanceMeters - route.distanceMeters) < 0.03 * route.distanceMeters }
            if (route.newMeters ?? 0) >= best + 200, same == false { routes.append(route) }
        }
    }

    private func bikeRoute(_ kind: StreetnavBikeRoute.Kind, from: CLLocationCoordinate2D, via: [CLLocationCoordinate2D],
                           to: CLLocationCoordinate2D) async -> StreetnavBikeRoute? {
        let points = [from] + via + [to]
        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/cycling/"
            + points.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";"))!
        components.queryItems = [
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "language", value: "fr"),
            // Only the start and the place are stops: the detours' points are passed through, as one leg.
            URLQueryItem(name: "waypoints", value: "0;\(points.count - 1)"),
            URLQueryItem(name: "access_token", value: MapboxOptions.accessToken),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let first = (try? JSONDecoder().decode(Directions.self, from: data))?.routes.first else { return nil }
        let coordinates = first.geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
        return StreetnavBikeRoute(kind: kind, coordinates: coordinates, distanceMeters: first.distance,
                                  durationSeconds: first.duration, via: via,
                                  newMeters: StreetnavLiveStreets.shared.newMetres(along: coordinates))
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
        let suggestions = results.prefix(8).enumerated().map { index, completion in
            StreetnavSuggestion(id: "\(index)-\(completion.title)", title: completion.title, subtitle: completion.subtitle,
                                source: .apple(completion))
        }
        Task { @MainActor in
            self.suggestions = suggestions
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
