import CoreLocation
@_spi(Experimental) import MapboxMaps
import SwiftUI

/// Mapbox map of the exploration state: streets already ridden, streets left to discover and the planned route.
///
/// The base map is Mapbox Standard in its default colours, without points of interest, seen in 3D like the city outside:
/// its light follows the sun where the rider is (dawn, day, dusk, night), or night in dark mode. Every line is a style layer drawn by the GPU:
/// colours, widths and dots are computed per street by the engine, lines glow at night (emissive), stay visible
/// behind 3D buildings (occlusion opacity), and the route is trimmed as it is ridden. The blue dot is the real
/// position from Core Location, asked for the first time the map shows it.
struct StreetnavExplorationMap: View {
    let segments: [ExplorationStreetSegment]
    let route: StreetnavRoute?
    let mode: PrototypeFlowState
    /// A place found by the search bar, and the bike route to it.
    var place: StreetnavPlace?
    var placeRoute: [CLLocationCoordinate2D]?
    var routeProgress: Double = 0
    /// How far the panel rises above the bottom of the safe area, live while it is dragged: Mapbox's logo sits on it.
    var panelOverlap: CGFloat = 0
    @Binding var viewport: Viewport
    /// Tilted city or map seen from above, switched by the « 3D » button as in Maps.
    var isThreeD: Binding<Bool> = .constant(true)
    var recenter: () -> Void = {}

    @State private var look: Look = .standard
    @State private var sunLight = StreetnavSunlight.preset(at: .now)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MapReader { proxy in
            map
                // Place names in French, like the rest of the app.
                .onStyleLoaded { _ in try? proxy.map?.localizeLabels(into: Locale(identifier: "fr")) }
        }
        .ignoresSafeArea()
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { sunLight = StreetnavSunlight.preset(at: $0) }
        // As in Maps, measured on its iOS 27 screens: map buttons 22 points from the edges, 16 above the panel on the right
        // and 21 on the left; they go once the panel is open.
        .overlay(alignment: .bottomTrailing) {
            if showsButtons {
                controls
                    .padding(.trailing, 22)
                    .padding(.bottom, panelOverlap + 14)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsButtons, mode.isRouteStep == false {
                threeDButton
                    .padding(.leading, 22)
                    .padding(.bottom, panelOverlap + 19)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsButtons)
        .accessibilityLabel("Carte des rues parcourues et des rues à découvrir")
    }

    private var map: Map {
        Map(viewport: $viewport) {
            Self.streetsSource(segments)
            streetLayer("rues-parcourues", status: .traveled)
                .lineColor(neutral)
                .lineOpacity(colorScheme == .dark ? 0.55 : 0.5)
                .lineWidth(Self.zoomed(1, 3, 7))
            streetLayer("rues-incertaines", status: .uncertain)
                .lineColor(neutral)
                .lineOpacity(0.35)
                .lineWidth(Self.zoomed(1, 2.5, 6))
                .lineDashArray([2, 2])
            streetLayer("rues-a-decouvrir", status: .untraveled)
                .lineColor(accent)
                .lineWidth(Self.zoomed(2, 4, 9))
                .lineDashArray([0, 2])
            streetLayer("rues-decouvertes", status: .completedDuringRide)
                .lineColor(accent)
                .lineWidth(Self.zoomed(2, 4, 9))

            if let route {
                Self.lineSource("itineraire", route.coordinates)
                routeHalo("itineraire-halo", source: "itineraire")
                routeLine("itineraire", source: "itineraire")
                    // The part already ridden fades out, as in Maps.
                    .lineTrimOffset(start: 0, end: max(0, min(1, routeProgress)))
                    .lineTrimColor(UIColor(white: 0.55, alpha: 0.5))
            }

            if let placeRoute {
                Self.lineSource("trajet-lieu", placeRoute)
                routeHalo("trajet-lieu-halo", source: "trajet-lieu")
                routeLine("trajet-lieu", source: "trajet-lieu")
            }
            if let place {
                MapViewAnnotation(coordinate: place.coordinate) {
                    StreetnavPlacePin(symbol: place.symbol)
                }
                .allowOverlap(true)
                .variableAnchors([ViewAnnotationAnchorConfig(anchor: .bottom)])
            }

            // Where the phone points while exploring, where the bike goes while riding.
            Puck2D(bearing: mode.isNavigationLike ? .course : .heading)
                .showsAccuracyRing(true)
        }
        .mapStyle(mapStyle)
        .ornamentOptions(OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(position: .topTrailing, margins: CGPoint(x: 16, y: 112), visibility: .adaptive),
            // Mapbox's logo and credits must stay visible. At the top left, where Maps has its weather badge, so that the
            // bottom of the screen is laid out like Maps; above the ride controls while riding.
            logo: LogoViewOptions(position: logoAtTop ? .topLeading : .bottomLeading,
                                  margins: CGPoint(x: logoAtTop ? 22 : 12, y: logoAtTop ? 6 : logoLift)),
            attributionButton: AttributionButtonOptions(position: logoAtTop ? .topLeading : .bottomLeading,
                                                        margins: CGPoint(x: logoAtTop ? 106 : 96, y: logoAtTop ? -12 : logoLift - 2))
        ))
    }

    private var logoAtTop: Bool { mode.isNavigationLike == false && mode != .arrived }

    private var logoLift: CGFloat {
        switch mode {
        case .paused: 296
        case .arrived: 438
        default: 236
        }
    }

    private var accent: UIColor {
        colorScheme == .dark ? UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1) : UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    }

    private var neutral: UIColor {
        colorScheme == .dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.45, alpha: 1)
    }

    private var mapStyle: MapStyle {
        var light: StandardLightPreset = colorScheme == .dark ? .night : sunLight
        var theme = StandardTheme.default
        #if DEBUG
        // Development: -mapLight dawn|day|dusk|night and -mapTheme default|faded|monochrome to compare looks.
        if let forced = UserDefaults.standard.string(forKey: "mapLight") { light = StandardLightPreset(rawValue: forced) }
        if let forced = UserDefaults.standard.string(forKey: "mapTheme") { theme = StandardTheme(rawValue: forced) }
        #endif
        switch look {
        case .standard:
            return .standard(theme: theme, lightPreset: light, showPointOfInterestLabels: false, showTransitLabels: false,
                             showPlaceLabels: true, showRoadLabels: true, showPedestrianRoads: true, show3dObjects: true)
        case .satellite:
            return .standardSatellite(lightPreset: light, showPointOfInterestLabels: false, showTransitLabels: false)
        }
    }

    /// A soft halo under a route, as in Maps during navigation.
    private func routeHalo(_ id: String, source: String) -> LineLayer {
        LineLayer(id: id, source: source)
            .slot(.middle)
            .lineCap(.round).lineJoin(.round)
            .lineColor(accent)
            .lineOpacity(0.18)
            .lineBlur(Self.zoomed(4, 8, 14))
            .lineWidth(Self.zoomed(10, 20, 36))
            .lineEmissiveStrength(1)
            .lineOcclusionOpacity(0.2)
    }

    private func routeLine(_ id: String, source: String) -> LineLayer {
        LineLayer(id: id, source: source)
            .slot(.middle)
            .lineCap(.round).lineJoin(.round)
            .lineColor(accent)
            .lineBorderColor(colorScheme == .dark ? UIColor(white: 0, alpha: 0.45) : UIColor(white: 1, alpha: 0.9))
            .lineBorderWidth(1.5)
            .lineWidth(Self.zoomed(7, 11, 18))
            .lineEmissiveStrength(1)
            .lineOcclusionOpacity(0.5)
    }

    private func streetLayer(_ id: String, status: StreetExplorationStatus) -> LineLayer {
        LineLayer(id: id, source: "rues")
            .filter(Exp(.eq) {
                Exp(.get) { "status" }
                status.rawValue
            })
            .slot(.middle)
            .lineCap(.round)
            .lineJoin(.round)
            .lineEmissiveStrength(1)
            .lineOcclusionOpacity(0.35)
    }

    /// Location and map type, stacked in one capsule like the Maps app.
    private var showsButtons: Bool { mode.isNavigationLike == false && mode != .arrived && panelOverlap < 380 }

    private var threeDButton: some View {
        Button {
            isThreeD.wrappedValue.toggle()
        } label: {
            Text(isThreeD.wrappedValue ? "2D" : "3D")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .streetnavGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isThreeD.wrappedValue ? "Vue de dessus" : "Vue en 3D")
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Type de carte", selection: $look) {
                    ForEach(Look.allCases) { look in
                        Label(look.title, systemImage: look.symbolName).tag(look)
                    }
                }
            } label: {
                Image(systemName: look == .standard ? "map.fill" : "globe.europe.africa.fill")
                    .frame(width: 48, height: 52)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Type de carte")

            Button(action: recenter) {
                Image(systemName: "location")
                    .frame(width: 48, height: 52)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Recentrer sur ma position")
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.primary)
        .streetnavGlass(in: Capsule(), interactive: true)
    }

    private enum Look: String, CaseIterable, Identifiable {
        case standard
        case satellite

        var id: String { rawValue }
        var title: String { self == .standard ? "Plan" : "Satellite" }
        var symbolName: String { self == .standard ? "map" : "globe.europe.africa" }
    }
}

extension StreetnavExplorationMap {
    /// Where the camera goes for each step of the flow, keeping `bottomInset` points clear for the panel or the cards.
    static func viewport(for mode: PrototypeFlowState, route: StreetnavRoute?, bottomInset: CGFloat, pitch: CGFloat = 50) -> Viewport {
        switch mode {
        case .routePreview, .readiness, .arrived:
            if let route { return focus(on: route.coordinates, padding: 40, bottomInset: bottomInset) }
            return Viewport.followPuck(zoom: 16.6, pitch: pitch).padding(.bottom, bottomInset)
        case _ where mode.isNavigationLike:
            // Tilted like Maps, turning with the ride: the route stays visible through the buildings (occlusion opacity).
            return Viewport.followPuck(zoom: 17, bearing: .course, pitch: 55).padding(.bottom, bottomInset)
        default:
            #if DEBUG
            // Development: -mapPitch 60 -mapZoom 16.2 to try other angles.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "mapPitch") != nil {
                return Viewport.followPuck(zoom: defaults.double(forKey: "mapZoom"), bearing: .constant(-25), pitch: defaults.double(forKey: "mapPitch"))
                    .padding(.bottom, bottomInset)
            }
            #endif
            // Close enough to read the streets around, tilted enough to see the buildings and their light, north up.
            return Viewport.followPuck(zoom: 16.6, pitch: pitch).padding(.bottom, bottomInset)
        }
    }

    static func focus(on coordinates: [CLLocationCoordinate2D], padding: CGFloat = 60, bottomInset: CGFloat = 0) -> Viewport {
        Viewport.overview(geometry: LineString(coordinates), geometryPadding: EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding))
            .padding(.bottom, bottomInset)
    }

    static func streetsSource(_ segments: [ExplorationStreetSegment]) -> GeoJSONSource {
        var source = GeoJSONSource(id: "rues")
        source.data = .featureCollection(FeatureCollection(features: segments.map { segment in
            var feature = Feature(geometry: LineString(segment.coordinates))
            feature.properties = ["status": .string(segment.status.rawValue), "name": .string(segment.name)]
            return feature
        }))
        return source
    }

    static func lineSource(_ id: String, _ coordinates: [CLLocationCoordinate2D]) -> GeoJSONSource {
        var source = GeoJSONSource(id: id)
        source.data = .geometry(.lineString(LineString(coordinates)))
        // Needed for the trim of the part already ridden.
        source.lineMetrics = true
        return source
    }

    /// A width that grows with the zoom level (values at zoom 12, 16 and 19), the way Maps draws its roads.
    static func zoomed(_ atZoom12: Double, _ atZoom16: Double, _ atZoom19: Double) -> Exp {
        Exp(.interpolate) {
            Exp(.exponential) { 1.5 }
            Exp(.zoom)
            12
            atZoom12
            16
            atZoom16
            19
            atZoom19
        }
    }
}

extension Color {
    static let streetnavRoute = Color.blue
}

/// The pin of a place found by the search bar, like the ones in Maps: its category's symbol in a red balloon.
private struct StreetnavPlacePin: View {
    let symbol: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.red))
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .rotationEffect(.degrees(180))
                .offset(y: -3)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .accessibilityLabel("Lieu recherché")
    }
}

extension StreetExplorationStatus {
    /// Same code as the map layers, for the legend and the street lists: one accent, the rest neutral.
    var mapColor: Color {
        switch self {
        case .traveled: .gray
        case .untraveled, .planned, .completedDuringRide: .blue
        case .uncertain: .gray.opacity(0.5)
        }
    }

    var mapStroke: StrokeStyle {
        switch self {
        case .traveled: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        case .untraveled: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [0.1, 7])
        case .planned, .completedDuringRide: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        case .uncertain: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [4, 4])
        }
    }
}

/// Where the sun stands for the rider, to light the map like the sky outside.
enum StreetnavSunlight {
    private static let location = CLLocationManager()

    /// Night under 6° below the horizon (end of civil twilight), dawn or dusk up to 6° above it, day higher.
    static func preset(at date: Date) -> StandardLightPreset {
        // Paris until a position is known: close enough for the sun anywhere in France.
        let coordinate = location.location?.coordinate ?? StreetnavMockData.parisCenter
        let now = elevation(at: date, of: coordinate)
        if now < -6 { return .night }
        if now > 6 { return .day }
        return elevation(at: date.addingTimeInterval(600), of: coordinate) > now ? .dawn : .dusk
    }

    /// Sun elevation in degrees, with the Astronomical Almanac's low-precision formulas (about 0.01° off until 2050).
    static func elevation(at date: Date, of coordinate: CLLocationCoordinate2D) -> Double {
        let radians = Double.pi / 180
        let days = date.timeIntervalSince1970 / 86_400 - 10_957.5  // since 2000-01-01 12:00 UTC
        let meanLongitude = 280.460 + 0.985_647_4 * days
        let meanAnomaly = (357.528 + 0.985_600_3 * days) * radians
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * radians
        let obliquity = (23.439 - 0.000_000_4 * days) * radians
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let siderealTime = (280.460_618_37 + 360.985_647_366_29 * days + coordinate.longitude) * radians
        let hourAngle = siderealTime - rightAscension
        let latitude = coordinate.latitude * radians
        return asin(sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)) / radians
    }
}
