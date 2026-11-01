import MapKit
import SwiftUI

/// Native MapKit map of the exploration state: streets already ridden, streets left to discover and the planned
/// route, on a muted base map without points of interest so that the lines carry the information.
struct StreetnavExplorationMap: View {
    let segments: [ExplorationStreetSegment]
    let route: StreetnavRoute?
    let mode: PrototypeFlowState
    let position: CLLocationCoordinate2D
    var routeLineWidth: Double = 8
    @Binding var camera: MapCameraPosition
    var recenter: () -> Void = {}

    @State private var look: Look = .standard
    @Namespace private var mapScope

    var body: some View {
        Map(position: $camera, scope: mapScope) {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.status.mapColor, style: segment.status.mapStroke)
            }

            if let route {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Color(uiColor: .systemBackground).opacity(0.9), style: StrokeStyle(lineWidth: routeLineWidth + 4, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Color.streetnavRoute, style: StrokeStyle(lineWidth: routeLineWidth, lineCap: .round, lineJoin: .round))
            }

            Annotation("Ma position", coordinate: position, anchor: .center) {
                StreetnavPositionPuck(showsHeading: mode.isNavigationLike)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(mapStyle)
        .mapControls {}
        .overlay(alignment: .topTrailing) {
            // During the ride the manoeuvre card owns the top of the screen.
            if mode.isNavigationLike == false {
                VStack(spacing: 10) {
                    controls
                    MapCompass(scope: mapScope)
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .mapScope(mapScope)
        .accessibilityLabel("Carte des rues parcourues et des rues à découvrir")
    }

    private var mapStyle: MapStyle {
        switch look {
        case .standard:
            .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite:
            .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        }
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
    /// Where the camera goes for each step of the flow.
    static func camera(for mode: PrototypeFlowState, route: StreetnavRoute?, position: CLLocationCoordinate2D) -> MapCameraPosition {
        switch mode {
        case .routePreview, .readiness:
            if let route { return .rect(rect(around: route.coordinates)) }
            return .camera(MapCamera(centerCoordinate: position, distance: 4200))
        case _ where mode.isNavigationLike:
            // Seen from above: with the camera tilted, MapKit lets buildings hide the route.
            return .camera(MapCamera(centerCoordinate: position, distance: 900, heading: 28))
        default:
            return .camera(MapCamera(centerCoordinate: position, distance: 4200))
        }
    }

    static func rect(around coordinates: [CLLocationCoordinate2D], margin: Double = 0.18) -> MKMapRect {
        let rect = coordinates
            .map(MKMapPoint.init)
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0))) }
        let padding = max(rect.width, rect.height, 400) * margin
        return rect.insetBy(dx: -padding, dy: -padding)
    }
}

extension Color {
    static let streetnavRoute = Color(red: 0.0, green: 0.74, blue: 0.56)
}

extension StreetExplorationStatus {
    var mapColor: Color {
        switch self {
        case .traveled: .blue.opacity(0.55)
        case .untraveled: .red
        case .planned: .streetnavRoute
        case .completedDuringRide: .green
        case .uncertain: .gray.opacity(0.7)
        }
    }

    var mapStroke: StrokeStyle {
        switch self {
        case .traveled: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        case .untraveled: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [1, 8])
        case .planned: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        case .completedDuringRide: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        case .uncertain: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [4, 6])
        }
    }
}

/// The blue dot of the Maps app, with an arrow while riding.
private struct StreetnavPositionPuck: View {
    var showsHeading: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.16))
                .frame(width: 46, height: 46)
            Circle()
                .fill(.white)
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Circle()
                .fill(.blue)
                .frame(width: 17, height: 17)
            if showsHeading {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Ma position")
    }
}
