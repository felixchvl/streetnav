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
    /// The other ways there, drawn thinner and grey under the one chosen, as Maps draws its other routes.
    var placeAlternatives: [[CLLocationCoordinate2D]] = []
    /// Every bike ride kept on the server (GeoJSON): where the rider has already been, until the streets are known.
    var rides: String?
    /// The streets around Paris, ridden (`r` = 1) or not (`r` = 0), GeoJSON.
    var streets: String?
    /// The streets ridden on this ride, before the server knows (StreetnavLiveStreets), GeoJSON.
    var live: String?
    /// The rides beyond Paris and the inner suburbs, where no street is measured (GET /tracks/outside), GeoJSON.
    var outside: String?
    var routeProgress: Double = 0
    /// How far the panel rises above the bottom of the safe area, live while it is dragged: Mapbox's logo sits on it.
    var panelOverlap: CGFloat = 0
    @Binding var viewport: Viewport
    /// Tilted city or map seen from above, switched by the « 3D » button as in Maps.
    var isThreeD: Binding<Bool> = .constant(true)
    var recenter: () -> Void = {}
    /// A point held while exploring, a building or not, to ride to.
    var choosePoint: ((CLLocationCoordinate2D, _ building: Bool) -> Void)?

    /// The building held, drawn selected while its place is shown.
    @State private var building: StandardBuildingsFeature?

    /// The map's heading, rounded to the degree so that the view only redraws when the compass would change.
    @State private var bearing: Double = 0
    @AppStorage(StreetnavStreetFilter.key) private var streetFilter: StreetnavStreetFilter = .all
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
                VStack(spacing: 10) {
                    zoomButtons
                    controls
                }
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
                    tiltButtons
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
            // The real relief at every zoom, from the IGN's survey (`relief`).
            Self.reliefSource
            Terrain(sourceId: "relief").exaggeration(1)
            if let streets {
                Self.streetsLayerSource(streets)
                // Each colour twice: over the buildings, blended with them, then in its own colour where it is in sight.
                if streetFilter.showsNotRidden { Self.streetsNotRidden(dark: colorScheme == .dark, behind: lightPreset) }
                if streetFilter.showsRidden { Self.streetsRidden(dark: colorScheme == .dark, behind: lightPreset) }
                // The streets still to ride that this ride has just turned teal, and the rides beyond the zones.
                ForEvery(extraRidden, id: \.source) { extra in
                    Self.geoJSONSource(extra.source, extra.geojson)
                    Self.streetsRidden(dark: colorScheme == .dark, behind: lightPreset, id: extra.source + "-derriere", source: extra.source)
                }
                if streetFilter.showsNotRidden { Self.streetsNotRidden(dark: colorScheme == .dark) }
                if streetFilter.showsRidden { Self.streetsRidden(dark: colorScheme == .dark) }
                ForEvery(extraRidden, id: \.source) { extra in
                    Self.streetsRidden(dark: colorScheme == .dark, id: extra.source, source: extra.source)
                }
            } else if let rides, streetFilter.showsRidden {
                Self.ridesSource(rides)
                // Where the rider has already been: the colour of the streets ridden, quiet.
                LineLayer(id: "sorties", source: "sorties")
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(Self.riddenColour(dark: colorScheme == .dark))
                    .lineOpacity(colorScheme == .dark ? 0.55 : 0.45)
                    .lineWidth(Self.zoomed(1.2, 3, 6))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.3)
            }
            // Standard's lane lines, crossings and arrows again, above the streets that would hide them.
            if Self.showsMarkings {
                Self.hdMarkingsSource
                ForEvery(Self.hdMarkings.lines, id: \.id) { $0 }
                ForEvery(Self.hdMarkings.symbols, id: \.id) { $0 }
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

            ForEvery(Array(placeAlternatives.enumerated()), id: \.offset) { number, alternative in
                Self.lineSource("trajet-autre-\(number)", alternative)
                LineLayer(id: "trajet-autre-\(number)", source: "trajet-autre-\(number)")
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(colorScheme == .dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.62, alpha: 1))
                    .lineBorderColor(colorScheme == .dark ? UIColor(white: 0, alpha: 0.45) : UIColor(white: 1, alpha: 0.9))
                    .lineBorderWidth(1.5)
                    .lineWidth(Self.zoomed(5, 8, 13))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.8)
                    .lineElevationReference(.ground)
                    .lineZOffset(Self.routeLift)
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

            // A point held becomes the place to ride to, as in Maps: the building there, or a pin. A tap does nothing, so
            // that moving the map never picks one by chance.
            if let choosePoint {
                LongPressInteraction(.standardBuildings) { held, context in
                    building = held
                    choosePoint(context.coordinate, true)
                    return true
                }
                LongPressInteraction { context in
                    building = nil
                    choosePoint(context.coordinate, false)
                    return true
                }
            }
            if place != nil, let id = building?.id {
                FeatureState(.standardBuildings, id: id, state: .init(select: true))
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

    private var accent: UIColor { Self.accent(dark: colorScheme == .dark) }

    private var neutral: UIColor {
        colorScheme == .dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.45, alpha: 1)
    }

    /// Drawn like the streets ridden, when the filter shows them.
    private var extraRidden: [(source: String, geojson: String)] {
        guard streetFilter.showsRidden else { return [] }
        return [("rues-direct", live), ("sorties-ailleurs", outside)].compactMap { source, geojson in geojson.map { (source, $0) } }
    }

    private var lightPreset: StandardLightPreset { Self.light(dark: colorScheme == .dark, sun: sunLight) }

    /// The light of both maps: the sun's where the rider is, or night in dark mode.
    static func light(dark: Bool, sun: StandardLightPreset) -> StandardLightPreset {
        #if DEBUG
        // Development: -mapLight dawn|day|dusk|night to compare looks.
        if let forced = UserDefaults.standard.string(forKey: "mapLight") { return StandardLightPreset(rawValue: forced) }
        #endif
        return dark ? .night : sun
    }

    private var mapStyle: MapStyle {
        var theme = StandardTheme.default
        #if DEBUG
        // Development: -mapTheme default|faded|monochrome to compare looks.
        if let forced = UserDefaults.standard.string(forKey: "mapTheme") { theme = StandardTheme(rawValue: forced) }
        #endif
        return Self.standardStyle(light: lightPreset, theme: theme)
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
            .lineOcclusionOpacity(0.3)
            .lineElevationReference(.ground)
            .lineZOffset(Self.routeLift)
    }

    /// Wider than any street, with a white edge (black at night): the streets ridden are blue too.
    private func routeLine(_ id: String, source: String) -> LineLayer {
        LineLayer(id: id, source: source)
            .slot(.middle)
            .lineCap(.round).lineJoin(.round)
            .lineColor(accent)
            .lineBorderColor(Self.routeEdge(dark: colorScheme == .dark))
            .lineBorderWidth(3)
            .lineWidth(Self.zoomed(10, 14, 22))
            .lineEmissiveStrength(1)
            .lineOcclusionOpacity(Self.routeThroughBuildings)
            .lineElevationReference(.ground)
            .lineZOffset(Self.routeLift)
    }

    /// The edge of the routes, on both maps.
    static func routeEdge(dark: Bool) -> UIColor { dark ? UIColor(white: 0.05, alpha: 1) : UIColor(white: 1, alpha: 1) }

    /// How much of a route still shows where a building stands in front of it, on both maps. Only lines lifted off
    /// the ground are drawn among the buildings: a line flat on the ground is simply covered by them.
    static let routeThroughBuildings = 0.9

    /// How high the routes float, in metres: above the streets (half a metre), so that the buildings do not cover them.
    static let routeLift = 1.0

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

    /// Closer or farther, as in Waze: while the map follows the rider, the new distance becomes the default one, kept
    /// between launches and followed by the navigation; a map moved by hand only zooms where it is.
    private var zoomButtons: some View {
        VStack(spacing: 0) {
            Button { zoom(closer: true) } label: {
                Image(systemName: "plus")
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Zoomer")
            Button { zoom(closer: false) } label: {
                Image(systemName: "minus")
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dézoomer")
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.primary)
        .streetnavGlass(in: Capsule(), interactive: true)
    }

    private func zoom(closer: Bool) {
        let padding = viewport.padding
        if let following = viewport.followPuck {
            let offset = StreetnavMapZoom.clamped(StreetnavMapZoom.offset + (closer ? StreetnavMapZoom.step : -StreetnavMapZoom.step))
            let change = offset - StreetnavMapZoom.offset
            guard change != 0 else { return }
            StreetnavMapZoom.offset = offset
            // Short and eased out, so that taps in a row keep up.
            withViewportAnimation(.easeOut(duration: 0.18)) {
                viewport = Viewport.followPuck(zoom: following.zoom + change, bearing: following.bearing, pitch: following.pitch)
                    .padding(padding)
            }
        } else if let state = camera.state {
            withViewportAnimation(.easeOut(duration: 0.18)) {
                viewport = Viewport.camera(center: state.center, zoom: state.zoom + (closer ? 1 : -1), bearing: state.bearing,
                                           pitch: state.pitch)
                    .padding(padding)
            }
        }
    }

    /// More or less tilted: while the map follows the rider, the new angle becomes the default one (StreetnavMapTilt),
    /// kept between launches and followed by the navigation; a map moved by hand only tilts where it is. From 2D, the
    /// first tilt goes back to 3D.
    private var tiltButtons: some View {
        VStack(spacing: 0) {
            Button { tilt(more: true) } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Incliner davantage")
            Button { tilt(more: false) } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Redresser")
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.primary)
        .streetnavGlass(in: Capsule(), interactive: true)
    }

    private func tilt(more: Bool) {
        guard isThreeD.wrappedValue else {
            if more { isThreeD.wrappedValue = true }
            return
        }
        let padding = viewport.padding
        let step = more ? StreetnavMapTilt.step : -StreetnavMapTilt.step
        if let following = viewport.followPuck {
            let offset = StreetnavMapTilt.clamped(StreetnavMapTilt.offset + step)
            let change = offset - StreetnavMapTilt.offset
            guard change != 0 else { return }
            StreetnavMapTilt.offset = offset
            withViewportAnimation(.easeOut(duration: 0.18)) {
                viewport = Viewport.followPuck(zoom: following.zoom, bearing: following.bearing,
                                               pitch: min(StreetnavMapTilt.maxPitch, max(0, following.pitch + change)))
                    .padding(padding)
            }
        } else if let state = camera.state {
            withViewportAnimation(.easeOut(duration: 0.18)) {
                viewport = Viewport.camera(center: state.center, zoom: state.zoom, bearing: state.bearing,
                                           pitch: min(StreetnavMapTilt.maxPitch, max(0, state.pitch + step)))
                    .padding(padding)
            }
        }
    }

    /// Which streets the map shows, then the location button, stacked in one capsule like the Maps app (where the first
    /// one picks the map type: no satellite view here, it has no 3D).
    private var controls: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Rues affichées", selection: $streetFilter) {
                    ForEach(StreetnavStreetFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.symbolName).tag(filter)
                    }
                }
            } label: {
                Image(systemName: streetFilter.symbolName)
                    .frame(width: 48, height: 52)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("Rues affichées : \(streetFilter.title)")

            Button(action: recenter) {
                Image(systemName: locationSymbol)
                    .frame(width: 48, height: 52)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(locationLabel)
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.primary)
        .streetnavGlass(in: Capsule(), interactive: true)
    }

    /// As in Maps: hollow while the map is moved by hand, filled while it follows the rider, with a line while it turns
    /// with where the phone points.
    private var locationSymbol: String {
        switch viewport.followPuck?.bearing {
        case .heading?: "location.north.line.fill"
        case .some: "location.fill"
        case nil: "location"
        }
    }

    private var locationLabel: String {
        switch viewport.followPuck?.bearing {
        case .heading?: "Revenir au nord"
        case .some: "Suivre ma direction"
        case nil: "Recentrer sur ma position"
        }
    }
}

extension StreetnavExplorationMap {
    /// Where the camera goes for each step of the flow, keeping `bottomInset` points clear for the panel or the cards.
    static func viewport(for mode: PrototypeFlowState, route: StreetnavRoute?, bottomInset: CGFloat, pitch: CGFloat = 50) -> Viewport {
        switch mode {
        case .routePreview, .readiness, .arrived:
            if let route { return focus(on: route.coordinates, padding: 40, bottomInset: bottomInset) }
            return Viewport.followPuck(zoom: 16.6 + StreetnavMapZoom.offset, pitch: pitch).padding(.bottom, bottomInset)
        case _ where mode.isNavigationLike:
            // Tilted like Maps, turning with the ride: the route stays visible through the buildings (occlusion opacity).
            return Viewport.followPuck(zoom: 17 + StreetnavMapZoom.offset, bearing: .course, pitch: StreetnavMapTilt.pitch(55))
                .padding(.bottom, bottomInset)
        default:
            #if DEBUG
            // Development: -mapPitch 60 -mapZoom 16.2 [-mapBearing 60] to try other angles.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "mapPitch") != nil {
                let bearing = defaults.object(forKey: "mapBearing") != nil ? defaults.double(forKey: "mapBearing") : -25
                return Viewport.followPuck(zoom: defaults.double(forKey: "mapZoom"), bearing: .constant(bearing), pitch: defaults.double(forKey: "mapPitch"))
                    .padding(.bottom, bottomInset)
            }
            #endif
            // Close enough to read the streets around, tilted enough to see the buildings and their light, north up.
            return Viewport.followPuck(zoom: 16.6 + StreetnavMapZoom.offset, pitch: pitch).padding(.bottom, bottomInset)
        }
    }

    /// The location button tapped again while following: closer, tilted, turning with where the phone points.
    static func headingViewport(bottomInset: CGFloat) -> Viewport {
        Viewport.followPuck(zoom: 17.6 + StreetnavMapZoom.offset, bearing: .heading, pitch: StreetnavMapTilt.pitch(60))
            .padding(.bottom, bottomInset)
    }

    /// The map runs under the status bar: the top keeps 60 more points clear, for the routes not to end under it.
    static func focus(on coordinates: [CLLocationCoordinate2D], padding: CGFloat = 60, bottomInset: CGFloat = 0) -> Viewport {
        Viewport.overview(geometry: LineString(coordinates),
                          geometryPadding: EdgeInsets(top: padding + 60, leading: padding, bottom: padding, trailing: padding))
            .padding(.bottom, bottomInset)
    }

    /// Blue, as routes are in every navigation app: the way to ride.
    static func accent(dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1) : UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    }

    /// Teal for what is done, the streets ridden, and coral for what is left: a pair apart from the blue of the routes
    /// and the green of the parks, a little brighter at night.
    static func riddenColour(dark: Bool) -> UIColor {
        dark ? StreetnavStreetLook.current.riddenDark : StreetnavStreetLook.current.ridden
    }

    static func notRiddenColour(dark: Bool) -> UIColor {
        dark ? StreetnavStreetLook.current.notRiddenDark : StreetnavStreetLook.current.notRidden
    }

    static var streetGlow: Double { StreetnavStreetLook.current.glow }

    /// The ground as the IGN surveyed it (MNT LiDAR HD, half a metre, and RGE ALTI, one metre, under Licence Ouverte),
    /// in Mapterhorn's open tiles down to zoom 17. Mapbox's own stops at zoom 14, about ten metres a pixel, which is why
    /// Standard flattens it from zoom 12 to 13.7: kept closer, it buried the buildings on the slopes, hid the roads and
    /// sank the bridges, under a city drawn to the metre. The ground of the survey has neither buildings nor bridges.
    static var reliefSource: RasterDemSource {
        var source = RasterDemSource(id: "relief")
        source.tiles = ["https://tiles.mapterhorn.com/{z}/{x}/{y}.webp"]
        source.encoding = .terrarium
        source.tileSize = 512
        source.maxzoom = 17
        source.attribution = "<a href=\"https://mapterhorn.com/attribution\">© Mapterhorn</a> · Relief : IGN (MNT LiDAR HD, RGE ALTI)"
        return source
    }

    // The streets of `streetsLayerSource`, here and under the route of the navigation map: every street not ridden yet
    // in red (the system red, lighter by day), those already ridden in green, apart from the blue of the routes, as
    // wide as their road. Opaque everywhere: where parts or streets overlap (the round ends of two parts, a crossing), translucent
    // lines add up into darker knots. So each colour comes twice: `behind` the buildings, drawn over them in its colour
    // already blended with theirs under that light, then above it in its own colour, hidden where a building is in front.

    static func streetsNotRidden(dark: Bool, behind light: StandardLightPreset? = nil) -> LineLayer {
        streets(id: light == nil ? "rues-jamais" : "rues-jamais-derriere", source: "rues-osm", ridden: 0,
                colour: notRiddenColour(dark: dark),
                behind: light, share: 0.6)
    }

    static func streetsRidden(dark: Bool, behind light: StandardLightPreset? = nil, id: String? = nil,
                              source: String = "rues-osm") -> LineLayer {
        streets(id: id ?? (light == nil ? "rues-faites" : "rues-faites-derriere"), source: source, ridden: 1,
                colour: riddenColour(dark: dark), behind: light, share: 0.65)
    }

    private static func streets(id: String, source: String, ridden: Int, colour: UIColor, behind light: StandardLightPreset?,
                                share: CGFloat) -> LineLayer {
        let look = StreetnavStreetLook.current
        return LineLayer(id: id, source: source)
            .filter(Exp(.eq) { Exp(.get) { "r" }; ridden })
            .slot(.middle)
            .lineCap(.round).lineJoin(.round)
            .lineColor(light.map { blend(colour, over: buildingColour($0), share: share) } ?? colour)
            .lineWidth(roadWidth(close: look.closeWidth, scale: ridden == 1 ? look.riddenScale : 1))
            .lineEmissiveStrength(streetGlow)
            .lineOcclusionOpacity(light == nil ? 0 : 1)
            .lineElevationReference(StreetnavStreetLook.current.elevated ? .ground : .none)
            .lineZOffset(StreetnavStreetLook.current.elevated ? 0.5 : 0)
    }

    /// In points, one curve that only grows with the zoom, as the traffic lines of Maps: never as wide as the road, so
    /// that the road, its lanes and markings always show. A street is `close` points wide at zoom 16 (1 at zoom 12, 7 at
    /// 22), the big roads up to 1.5 points more, the service roads and paths less. `scale` thins the streets ridden.
    private static func roadWidth(close: Double, scale: Double) -> Exp {
        func widths(_ street: Double) -> Exp {
            byRoadClass(motorway: (street + 1.5) * scale, primary: (street + 1) * scale, secondary: (street + 0.5) * scale,
                        street: street * scale, link: (street - 0.3) * scale, service: street * 0.75 * scale,
                        path: street * 0.6 * scale)
        }
        return Exp(.interpolate) {
            Exp(.linear)
            Exp(.zoom)
            12
            widths(1)
            14
            widths(1 + (close - 1) * 0.5)
            16
            widths(close)
            18
            widths(close + 1)
            22
            widths(close + 3)
        }
    }

    /// The face of Standard's buildings under each light, measured on its screens (between their roofs and their walls).
    private static func buildingColour(_ light: StandardLightPreset) -> UIColor {
        switch light {
        case .night: UIColor(red: 0.17, green: 0.18, blue: 0.26, alpha: 1)
        case .dusk: UIColor(red: 0.36, green: 0.35, blue: 0.47, alpha: 1)
        case .dawn: UIColor(red: 0.91, green: 0.85, blue: 0.80, alpha: 1)
        default: UIColor(red: 0.89, green: 0.87, blue: 0.84, alpha: 1)
        }
    }

    private static func blend(_ colour: UIColor, over base: UIColor, share: CGFloat) -> UIColor {
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (r0, g0, b0, a0) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        base.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
        return UIColor(red: r0 + (r - r0) * share, green: g0 + (g - g0) * share, blue: b0 + (b - b0) * share, alpha: 1)
    }

    static var showsMarkings: Bool {
        #if DEBUG
        // Development: -mapMarkings NO to compare.
        if UserDefaults.standard.object(forKey: "mapMarkings") != nil { return UserDefaults.standard.bool(forKey: "mapMarkings") }
        #endif
        return true
    }

    /// Standard's HD road markings (StreetnavHDMarkings), read once.
    static let hdMarkings: (lines: [LineLayer], symbols: [SymbolLayer]) = {
        guard let objects = try? JSONSerialization.jsonObject(with: Data(StreetnavHDMarkings.layersJSON.utf8)) as? [[String: Any]]
        else { return ([], []) }
        var lines: [LineLayer] = []
        var symbols: [SymbolLayer] = []
        for object in objects {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { continue }
            switch object["type"] as? String {
            case "line": if let layer = try? JSONDecoder().decode(LineLayer.self, from: data) { lines.append(layer) }
            case "symbol": if let layer = try? JSONDecoder().decode(SymbolLayer.self, from: data) { symbols.append(layer) }
            default: break
            }
        }
        return (lines, symbols)
    }()

    static var hdMarkingsSource: VectorSource {
        var source = VectorSource(id: StreetnavHDMarkings.sourceID)
        source.url = StreetnavHDMarkings.sourceURL
        return source
    }

    private static func byRoadClass(motorway: Double, primary: Double, secondary: Double, street: Double, link: Double,
                                    service: Double, path: Double) -> Exp {
        Exp(.match) {
            Exp(.get) { "k" }
            0
            motorway
            1
            primary
            2
            secondary
            4
            link
            5
            service
            6
            path
            street
        }
    }

    static func streetsLayerSource(_ geojson: String) -> GeoJSONSource {
        var source = GeoJSONSource(id: "rues-osm")
        source.data = .string(geojson)
        // 88,000 street parts: tiles cut up to zoom 14 only, then scaled, to keep the memory down.
        source.maxzoom = 14
        source.tolerance = 0.5
        return source
    }

    /// Mapbox Standard as set in Studio (mapbox://styles/felixchvl/cmkxx6roj006u01shagrg0bfo, 2026-11-03), with
    /// Streetnav's own choices kept: the light of the hour, no transit labels and no points of interest at all (nor
    /// landmark icons). From Studio: no names of districts and towns, no footpaths (the streets layer draws those a
    /// bike may ride), detailed façades, HD roads (lane markings, crossings, bridges and tunnels in 3D, from zoom 16
    /// where Mapbox has them), no indoor plans (billed apart).
    static func standardStyle(light: StandardLightPreset, theme: StandardTheme = .default) -> MapStyle {
        var facades = true
        var hdRoads = true
        #if DEBUG
        // Development: -mapFacades NO and -mapHD NO to compare.
        if UserDefaults.standard.object(forKey: "mapFacades") != nil { facades = UserDefaults.standard.bool(forKey: "mapFacades") }
        if UserDefaults.standard.object(forKey: "mapHD") != nil { hdRoads = UserDefaults.standard.bool(forKey: "mapHD") }
        #endif
        return .standard(theme: theme, lightPreset: light, showPointOfInterestLabels: false, showTransitLabels: false,
                  showPlaceLabels: false, showRoadLabels: true, showPedestrianRoads: false, show3dObjects: true,
                  show3dFacades: facades, showHdRoads: hdRoads, showIndoor: false, showLandmarkIconLabels: false,
                  showLandmarkIcons: false)
    }

    static func geoJSONSource(_ id: String, _ geojson: String) -> GeoJSONSource {
        var source = GeoJSONSource(id: id)
        source.data = .string(geojson)
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

/// How much closer than usual the maps follow the rider, in zoom levels, set with their + and − buttons as in Waze. Kept
/// between launches.
enum StreetnavMapZoom {
    static let key = "streetnav.mapZoomOffset"
    static let step = 0.5
    private static let range = -3.0...2.0

    static var offset: Double {
        get { UserDefaults.standard.double(forKey: key) }
        set { UserDefaults.standard.set(clamped(newValue), forKey: key) }
    }

    static func clamped(_ offset: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, offset))
    }
}

/// How the streets ridden and still to ride are drawn, chosen side by side in the simulator on 2026-11-03 among seven
/// looks (as wide as the road in metres, thin lines with or without an edge, lighter streets ridden…): a thin line on
/// the road that only grows with the zoom, as Maps draws its traffic, so that the road, its lanes and markings show;
/// the streets ridden a little thinner, the coral of those still to ride brighter, both lit a little more at night. In
/// debug builds, launch arguments override each value to compare looks again: -lookClose 4 -lookRiddenScale 0.8
/// -lookGlow 0.9, and colours as hex numbers, -lookRidden 2A9E8F -lookRiddenDark 3FBFAA -lookNotRidden E8553E
/// -lookNotRiddenDark FF7A5C.
struct StreetnavStreetLook {
    /// A street's width at zoom 16, in points.
    var closeWidth = 4.0
    var riddenScale = 0.8
    var glow = 0.9
    /// Drawn in 3D just above the ground rather than draped on the relief: draped, they could not be seen through the
    /// buildings any more.
    var elevated = true
    var ridden = UIColor(red: 0.16, green: 0.62, blue: 0.56, alpha: 1)
    var riddenDark = UIColor(red: 0.25, green: 0.75, blue: 0.67, alpha: 1)
    var notRidden = UIColor(red: 0.91, green: 0.33, blue: 0.24, alpha: 1)
    var notRiddenDark = UIColor(red: 1, green: 0.48, blue: 0.36, alpha: 1)

    static let current: StreetnavStreetLook = {
        var look = StreetnavStreetLook()
        #if DEBUG
        let defaults = UserDefaults.standard
        func number(_ key: String) -> Double? { defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : nil }
        func colour(_ key: String) -> UIColor? {
            guard let hex = defaults.string(forKey: key), let value = UInt32(hex, radix: 16) else { return nil }
            return UIColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        look.closeWidth = number("lookClose") ?? look.closeWidth
        look.riddenScale = number("lookRiddenScale") ?? look.riddenScale
        look.glow = number("lookGlow") ?? look.glow
        if defaults.object(forKey: "lookElevated") != nil { look.elevated = defaults.bool(forKey: "lookElevated") }
        look.ridden = colour("lookRidden") ?? look.ridden
        look.riddenDark = colour("lookRiddenDark") ?? look.riddenDark
        look.notRidden = colour("lookNotRidden") ?? look.notRidden
        look.notRiddenDark = colour("lookNotRiddenDark") ?? look.notRiddenDark
        #endif
        return look
    }()
}

/// How much more tilted than usual the maps are, in degrees, set with their tilt buttons. Kept between launches.
enum StreetnavMapTilt {
    static let key = "streetnav.mapTiltOffset"
    static let step = 10.0
    static let maxPitch = 80.0
    private static let range = -40.0...25.0

    static var offset: Double {
        get { UserDefaults.standard.double(forKey: key) }
        set { UserDefaults.standard.set(clamped(newValue), forKey: key) }
    }

    static func clamped(_ offset: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, offset))
    }

    /// A view's usual pitch with the offset, within what Mapbox shows.
    static func pitch(_ usual: Double, offset: Double = offset) -> Double {
        min(maxPitch, max(0, usual + offset))
    }
}

/// Which streets both maps show: those ridden (blue), those still to ride (red), both or none. Kept between launches.
enum StreetnavStreetFilter: String, CaseIterable, Identifiable {
    case all
    case ridden
    case notRidden
    case none

    static let key = "streetnav.streetFilter"

    var id: String { rawValue }
    var showsRidden: Bool { self == .all || self == .ridden }
    var showsNotRidden: Bool { self == .all || self == .notRidden }

    var title: String {
        switch self {
        case .all: "Toutes les rues"
        case .ridden: "Rues parcourues"
        case .notRidden: "Rues à découvrir"
        case .none: "Aucune"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "road.lanes"
        case .ridden: "checkmark.circle"
        case .notRidden: "circle.dashed"
        case .none: "eye.slash"
        }
    }
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

/// The compass of Maps, measured on its iOS 27 screens: a glass button with a large N, 16 faint ticks (east, south and
/// west darker) and a red mark that points north.
private struct StreetnavCompass: View {
    let bearing: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ZStack {
                    // Every 22.5°, from 15 to 19.8 points from the centre; none at north, where the red mark is.
                    ForEach(1..<16, id: \.self) { tick in
                        Capsule()
                            .fill(Color.primary.opacity(tick % 4 == 0 ? 0.65 : 0.135))
                            .frame(width: 1.85, height: 4.8)
                            .offset(y: -17.4)
                            .rotationEffect(.degrees(Double(tick) * 22.5))
                    }
                    // From 15 to 20 points from the centre. Deeper than the system red, which the glass pales: it comes out
                    // as bright as in Maps.
                    NorthMark()
                        .fill(Color(red: 1, green: 0.05, blue: 0.09))
                        .frame(width: 6.2, height: 5.8)
                        .offset(y: -17.85)
                }
                .rotationEffect(.degrees(-bearing))
                // A little low, as in Maps.
                Text(verbatim: "N")
                    .font(.system(size: 19.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .offset(y: 0.2)
            }
            .frame(width: 48, height: 48)
            .streetnavGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Orienter la carte vers le nord")
    }

    /// A triangle pointing out of the disc, its corners rounded.
    private struct NorthMark: Shape {
        func path(in rect: CGRect) -> Path {
            let top = CGPoint(x: rect.midX, y: rect.minY)
            let right = CGPoint(x: rect.maxX, y: rect.maxY)
            let left = CGPoint(x: rect.minX, y: rect.maxY)
            return Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addArc(tangent1End: right, tangent2End: top, radius: 0.6)
                path.addArc(tangent1End: top, tangent2End: left, radius: 0.6)
                path.addArc(tangent1End: left, tangent2End: right, radius: 0.6)
                path.closeSubpath()
            }
        }
    }
}
