import CoreLocation
@_spi(Experimental) import MapboxMaps
import SwiftUI

/// Mapbox map of the exploration state: streets already ridden, streets left to discover and the planned route.
///
/// The base map is Mapbox Standard in its monochrome theme, without points of interest, in day or night light with the
/// system appearance, so that the streets carry the information. Every line is a style layer drawn by the GPU:
/// colours, widths and dots are computed per street by the engine, lines glow at night (emissive), stay visible
/// behind 3D buildings (occlusion opacity), and the route is trimmed as it is ridden. The blue dot is the real
/// position from Core Location, asked for the first time the map shows it.
struct StreetnavExplorationMap: View {
    let segments: [ExplorationStreetSegment]
    let route: StreetnavRoute?
    let mode: PrototypeFlowState
    var routeProgress: Double = 0
    /// How far the panel rises above the bottom of the safe area, live while it is dragged: Mapbox's logo sits on it.
    var panelOverlap: CGFloat = 0
    @Binding var viewport: Viewport
    var recenter: () -> Void = {}

    @State private var look: Look = .standard
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MapReader { proxy in
            map
                // Place names in French, like the rest of the app.
                .onStyleLoaded { _ in try? proxy.map?.localizeLabels(into: Locale(identifier: "fr")) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            // During the ride the manoeuvre card owns the top of the screen.
            if mode.isNavigationLike == false {
                controls
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
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
                Self.routeSource(route)
                // A soft halo under the route, as in Maps during navigation.
                LineLayer(id: "itineraire-halo", source: "itineraire")
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(accent)
                    .lineOpacity(0.18)
                    .lineBlur(Self.zoomed(4, 8, 14))
                    .lineWidth(Self.zoomed(10, 20, 36))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.2)
                LineLayer(id: "itineraire", source: "itineraire")
                    .slot(.middle)
                    .lineCap(.round).lineJoin(.round)
                    .lineColor(accent)
                    .lineBorderColor(colorScheme == .dark ? UIColor(white: 0, alpha: 0.45) : UIColor(white: 1, alpha: 0.9))
                    .lineBorderWidth(1.5)
                    .lineWidth(Self.zoomed(7, 11, 18))
                    .lineEmissiveStrength(1)
                    .lineOcclusionOpacity(0.5)
                    // The part already ridden fades out, as in Maps.
                    .lineTrimOffset(start: 0, end: max(0, min(1, routeProgress)))
                    .lineTrimColor(UIColor(white: 0.55, alpha: 0.5))
            }

            // Where the phone points while exploring, where the bike goes while riding.
            Puck2D(bearing: mode.isNavigationLike ? .course : .heading)
                .showsAccuracyRing(true)
        }
        .mapStyle(mapStyle)
        .ornamentOptions(OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(position: .topTrailing, margins: CGPoint(x: 16, y: 112), visibility: .adaptive),
            // Mapbox's logo and credits must stay visible: just above the panel or the ride controls.
            logo: LogoViewOptions(position: .bottomLeading, margins: CGPoint(x: 12, y: logoLift)),
            attributionButton: AttributionButtonOptions(position: .bottomLeading, margins: CGPoint(x: 96, y: logoLift - 2))
        ))
    }

    private var logoLift: CGFloat {
        switch mode {
        case .paused: 296
        case .arrived: 438
        case _ where mode.isNavigationLike: 236
        // Behind the panel when it is fully open, where the map is hidden anyway.
        default: min(panelOverlap, 600) + 8
        }
    }

    private var accent: UIColor {
        colorScheme == .dark ? UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1) : UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    }

    private var neutral: UIColor {
        colorScheme == .dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.45, alpha: 1)
    }

    private var mapStyle: MapStyle {
        let light: StandardLightPreset = colorScheme == .dark ? .night : .day
        switch look {
        case .standard:
            // Monochrome: greys and white only, so that the streets are the only colour on the map.
            return .standard(theme: .monochrome, lightPreset: light, showPointOfInterestLabels: false, showTransitLabels: false,
                             showPlaceLabels: true, showRoadLabels: true, showPedestrianRoads: true, show3dObjects: true)
        case .satellite:
            return .standardSatellite(lightPreset: light, showPointOfInterestLabels: false, showTransitLabels: false)
        }
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
    private var controls: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Type de carte", selection: $look) {
                    ForEach(Look.allCases) { look in
                        Label(look.title, systemImage: look.symbolName).tag(look)
                    }
                }
            } label: {
                Image(systemName: look == .standard ? "map" : "globe.europe.africa")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Type de carte")

            Divider()
                .frame(width: 26)

            Button(action: recenter) {
                Image(systemName: "location")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Recentrer sur ma position")
        }
        .font(.system(size: 17, weight: .medium))
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
    static func viewport(for mode: PrototypeFlowState, route: StreetnavRoute?, bottomInset: CGFloat) -> Viewport {
        switch mode {
        case .routePreview, .readiness, .arrived:
            if let route { return focus(on: route.coordinates, padding: 40, bottomInset: bottomInset) }
            return Viewport.followPuck(zoom: 14.6).padding(.bottom, bottomInset)
        case _ where mode.isNavigationLike:
            // Tilted like Maps, turning with the ride: the route stays visible through the buildings (occlusion opacity).
            return Viewport.followPuck(zoom: 17, bearing: .course, pitch: 55).padding(.bottom, bottomInset)
        default:
            return Viewport.followPuck(zoom: 14.6).padding(.bottom, bottomInset)
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

    static func routeSource(_ route: StreetnavRoute) -> GeoJSONSource {
        var source = GeoJSONSource(id: "itineraire")
        source.data = .geometry(.lineString(LineString(route.coordinates)))
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
