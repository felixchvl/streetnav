import CoreLocation
import MapKit
import SwiftUI

#if canImport(MapboxMaps)
@_spi(Experimental) import MapboxMaps
#endif

protocol StreetMapRendering {}

struct StreetnavMapSurface: View, StreetMapRendering {
    let segments: [ExplorationStreetSegment]
    let route: StreetnavRoute?
    let mode: PrototypeFlowState
    var tuning: StreetnavPrototypeTuning = StreetnavPrototypeTuning()
    var muted: Bool = false

    private var center: CLLocationCoordinate2D { StreetnavMockData.parisCenter }

    var body: some View {
        ZStack {
            baseMap
                .saturation(muted ? 0.45 : 0.8)
                .contrast(muted ? 0.88 : 1.0)
                .brightness(muted ? -0.04 : 0)

            GeometryReader { proxy in
                StreetnavMapOverlay(
                    size: proxy.size,
                    segments: segments,
                    route: route,
                    mode: mode,
                    tuning: tuning
                )
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityLabel("Carte de Paris avec rues deja parcourues, rues a decouvrir et itineraire propose")
    }

    @ViewBuilder
    private var baseMap: some View {
        #if canImport(MapboxMaps)
        Map(initialViewport: .camera(center: center, zoom: tuning.mapZoom, bearing: mode.isNavigationLike ? 28 : 0, pitch: mode.isNavigationLike ? tuning.mapPitch : 0))
            .mapStyle(.standard(lightPreset: mode == .navigating || mode == .weakGPS ? .dusk : .day))
            .overlay(alignment: .topLeading) {
                Text("Mapbox")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 58)
                    .padding(.leading, 16)
                    .accessibilityHidden(true)
            }
        #else
        Map(position: .constant(.region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)))))
            .mapStyle(mode.isNavigationLike ? .hybrid(elevation: .realistic) : .standard(elevation: .flat))
            .overlay(alignment: .topLeading) {
                Text("MapKit")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 58)
                    .padding(.leading, 16)
                    .accessibilityHidden(true)
            }
        #endif
    }
}

private struct StreetnavMapOverlay: View {
    let size: CGSize
    let segments: [ExplorationStreetSegment]
    let route: StreetnavRoute?
    let mode: PrototypeFlowState
    let tuning: StreetnavPrototypeTuning
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, canvasSize in
            for segment in segments {
                var path = Path()
                for (index, coordinate) in segment.coordinates.enumerated() {
                    let point = point(for: coordinate, in: canvasSize)
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                let style = style(for: segment.status)
                context.stroke(path, with: .color(style.color.opacity(style.opacity)), style: StrokeStyle(lineWidth: style.width, lineCap: .round, lineJoin: .round, dash: style.dash))
            }

            if let route {
                var routePath = Path()
                for (index, coordinate) in route.coordinates.enumerated() {
                    let point = point(for: coordinate, in: canvasSize)
                    index == 0 ? routePath.move(to: point) : routePath.addLine(to: point)
                }
                context.stroke(routePath, with: .color(.mint.opacity(mode.isNavigationLike ? 0.96 : 0.88)), style: StrokeStyle(lineWidth: tuning.routeLineWidth + (mode.isNavigationLike ? 3 : 0), lineCap: .round, lineJoin: .round))
            }
        }
        .overlay(alignment: .center) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: mode.isNavigationLike ? 34 : 28, weight: .semibold))
                .foregroundStyle(.white, .blue)
                .shadow(radius: 6)
                .accessibilityLabel("Position actuelle")
        }
        .opacity(tuning.overlayOpacity)
    }

    private func style(for status: StreetExplorationStatus) -> (color: Color, width: CGFloat, opacity: Double, dash: [CGFloat]) {
        switch status {
        case .traveled:
            return (.blue, 5, 0.58, [])
        case .untraveled:
            return (.red, 6, 0.78, [8, 7])
        case .planned:
            return (.mint, 8, 0.9, [])
        case .completedDuringRide:
            return (.green, 7, 0.88, [])
        case .uncertain:
            return (.gray, 5, 0.62, [4, 6])
        }
    }

    private func point(for coordinate: CLLocationCoordinate2D, in canvasSize: CGSize) -> CGPoint {
        let minLat = 48.846
        let maxLat = 48.874
        let minLon = 2.360
        let maxLon = 2.402
        let x = (coordinate.longitude - minLon) / (maxLon - minLon) * canvasSize.width
        let y = (maxLat - coordinate.latitude) / (maxLat - minLat) * canvasSize.height
        return CGPoint(x: max(0, min(canvasSize.width, x)), y: max(0, min(canvasSize.height, y)))
    }
}

extension PrototypeFlowState {
    var isNavigationLike: Bool {
        switch self {
        case .navigating, .approachingNewStreet, .completedNewStreet, .rerouting, .weakGPS, .paused:
            true
        default:
            false
        }
    }
}
