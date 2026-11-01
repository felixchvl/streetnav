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
    /// Every bike ride kept on the server (GeoJSON): where the rider has already been, until the streets are known.
    var rides: String?
    /// The streets around Paris, ridden (`r` = 1) or not (`r` = 0), GeoJSON.
    var streets: String?
    var routeProgress: Double = 0
    /// How far the panel rises above the bottom of the safe area, live while it is dragged: Mapbox's logo sits on it.
    var panelOverlap: CGFloat = 0
    @Binding var viewport: Viewport
    /// Tilted city or map seen from above, switched by the « 3D » button as in Maps.
    var isThreeD: Binding<Bool> = .constant(true)
    var recenter: () -> Void = {}

    @State private var look: Look = .standard
    /// The map's heading, rounded to the degree so that the view only redraws when the compass would change.
    @State private var bearing: Double = 0
    @State private var camera = CameraBox()
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
                // As in Maps: the compass, only while the map is turned, above the 2D/3D button.
                VStack(spacing: 10) {
                    if abs(bearing) >= 2 {
                        StreetnavCompass(bearing: bearing, action: pointNorth)
                            .transition(.scale.combined(with: .opacity))
                    }
                    threeDButton
                }
                .padding(.leading, 22)
                // Above Mapbox's logo, which sits on the panel where Maps has its Look Around button.
                .padding(.bottom, panelOverlap + 46)
                .transition(.opacity)
                .animation(.snappy, value: abs(bearing) >= 2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsButtons)
        .accessibilityLabel("Carte des rues parcourues et des rues à découvrir")
    }

    private var map: Map {
        Map(viewport: $viewport) {
            if let streets {
                Self.streetsLayerSource(streets)
                // Every street not ridden yet, quiet; those already ridden in the accent, as Wandrer colours them.
                LineLayer(id: "rues-jamais", source: "rues-osm")
                    .filter(Exp(.eq) { Exp(.get) { "r" }; 0 })
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(colorScheme == .dark ? UIColor(white: 1, alpha: 1) : UIColor(white: 0.25, alpha: 1))
                    .lineOpacity(colorScheme == .dark ? 0.32 : 0.35)
                    .lineWidth(Self.zoomed(0.8, 2, 5))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.2)
                LineLayer(id: "rues-faites", source: "rues-osm")
                    .filter(Exp(.eq) { Exp(.get) { "r" }; 1 })
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(accent)
                    .lineOpacity(0.9)
                    .lineWidth(Self.zoomed(1.2, 3, 6))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.35)
            } else if let rides {
                Self.ridesSource(rides)
                // Where the rider has already been: the accent, quiet, under the streets still to discover.
                LineLayer(id: "sorties", source: "sorties")
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(accent)
                    .lineOpacity(colorScheme == .dark ? 0.55 : 0.45)
                    .lineWidth(Self.zoomed(1.2, 3, 6))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.3)
            }
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
        .onCameraChanged { changed in
            let state = changed.cameraState
            camera.state = state
            // -180…180, whole degrees.
            let heading = (state.bearing + 540).truncatingRemainder(dividingBy: 360) - 180
            if heading.rounded() != bearing { bearing = heading.rounded() }
        }
        .ornamentOptions(OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            // Streetnav draws its own, like the one in Maps.
            compass: CompassViewOptions(visibility: .hidden),
            // Mapbox's logo and credits must stay visible: just above the panel, under the 2D/3D button, or above the ride
            // controls while riding.
            logo: LogoViewOptions(position: .bottomLeading, margins: CGPoint(x: 22, y: logoLift)),
            attributionButton: AttributionButtonOptions(position: .bottomLeading, margins: CGPoint(x: 106, y: logoLift - 2))
        ))
    }

    private var logoLift: CGFloat {
        switch mode {
        case .paused: 296
        case .arrived: 438
        case _ where mode.isNavigationLike: 236
        // Behind the panel once it is fully open, where the map is hidden anyway.
        default: min(panelOverlap, 600) + 12
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
    /// Turns the map back to north where it is, as the compass in Maps does.
    private func pointNorth() {
        guard let state = camera.state else { return }
        withViewportAnimation(.default(maxDuration: 0.5)) {
            // Same padding, so that the map turns about the same point instead of sliding.
            let padding = state.padding
            viewport = Viewport.camera(center: state.center, zoom: state.zoom, bearing: 0, pitch: state.pitch)
                .padding(EdgeInsets(top: padding.top, leading: padding.left, bottom: padding.bottom, trailing: padding.right))
        }
    }

    final class CameraBox {
        var state: CameraState?
    }

    private var showsButtons: Bool { mode.isNavigationLike == false && mode != .arrived && panelOverlap < 380 }

    private var threeDButton: some View {
        Button {
            isThreeD.wrappedValue.toggle()
        } label: {
            // SF Pro Rounded, as in Maps.
            Text(isThreeD.wrappedValue ? "2D" : "3D")
                .font(.system(size: 17, weight: .medium, design: .rounded))
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

    static func streetsLayerSource(_ geojson: String) -> GeoJSONSource {
        var source = GeoJSONSource(id: "rues-osm")
        source.data = .string(geojson)
        // 88,000 street parts: tiles cut up to zoom 14 only, then scaled, to keep the memory down.
        source.maxzoom = 14
        source.tolerance = 0.5
        return source
    }

    static func ridesSource(_ geojson: String) -> GeoJSONSource {
        var source = GeoJSONSource(id: "sorties")
        source.data = .string(geojson)
        // Lighter tiles: the tracks are already simplified to about 5 metres on the server.
        source.tolerance = 0.5
        return source
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

/// The compass of Maps: a glass button with a large N, a ring of ticks and a red mark that points north.
private struct StreetnavCompass: View {
    let bearing: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ZStack {
                    ForEach(0..<24, id: \.self) { tick in
                        Capsule()
                            .fill(Color.primary.opacity(tick % 6 == 0 ? 0.9 : 0.55))
                            .frame(width: 1.5, height: tick % 6 == 0 ? 4.5 : 3)
                            .offset(y: -18)
                            .rotationEffect(.degrees(Double(tick) * 15))
                    }
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.red)
                        .offset(y: -18)
                }
                .rotationEffect(.degrees(-bearing))
                Text(verbatim: "N")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(width: 48, height: 48)
            .streetnavGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Orienter la carte vers le nord")
    }
}
