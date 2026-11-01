import Combine
import MapboxDirections
@_spi(Experimental) import MapboxMaps
import MapboxNavigationCore
import SwiftUI

/// The ride to a place: Mapbox's navigation map (position snapped to the street, camera that anticipates the turns,
/// route that fades behind the rider, arrows at the turns) under Streetnav's own glass cards, like Maps.
struct StreetnavGuidanceView: View {
    @ObservedObject private var guidance = StreetnavGuidance.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var sunLight = StreetnavSunlight.preset(at: .now)

    var body: some View {
        StreetnavGuidanceMap(guidance: guidance, light: colorScheme == .dark ? .night : sunLight)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if guidance.hasArrived == false {
                    maneuverCard
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                Group {
                    if guidance.hasArrived { arrivalCard } else { rideCard }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .animation(.snappy, value: guidance.hasArrived)
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { sunLight = StreetnavSunlight.preset(at: $0) }
            // The screen stays on during the ride, as in Maps.
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Cards

    private var maneuverCard: some View {
        HStack(spacing: 14) {
            Image(systemName: Self.symbol(for: guidance.instruction?.primaryInstruction))
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(stepDistance)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(guidance.instruction?.primaryInstruction.text ?? "Calcul de l'itinéraire…")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var rideCard: some View {
        HStack(alignment: .center, spacing: 0) {
            StreetnavStat(label: "Arrivée", value: arrivalTime, unit: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            StreetnavStat(label: "Restant", value: remainingTime.value, unit: remainingTime.unit)
                .frame(maxWidth: .infinity, alignment: .leading)
            StreetnavStat(label: "Distance", value: remainingDistance.value, unit: remainingDistance.unit)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive) {
                guidance.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .accessibilityLabel("Terminer la navigation")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var arrivalCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrivé")
                        .font(.title2.weight(.bold))
                    Text(guidance.destinationName)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "flag.checkered")
                    .font(.title2)
            }
            Button {
                guidance.stop()
            } label: {
                Text("Terminé")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(20)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    // MARK: Values

    private var stepDistance: String {
        guard let meters = guidance.progress?.currentLegProgress.currentStepProgress.distanceRemaining else { return "—" }
        return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var arrivalTime: String {
        guard let seconds = guidance.progress?.durationRemaining else { return "—" }
        return Date.now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }

    private var remainingTime: (value: String, unit: String?) {
        guard let seconds = guidance.progress?.durationRemaining else { return ("—", nil) }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? ("\(minutes)", "min") : ("\(minutes / 60) h \(String(format: "%02d", minutes % 60))", nil)
    }

    private var remainingDistance: (value: String, unit: String?) {
        guard let meters = guidance.progress?.distanceRemaining else { return ("—", nil) }
        if meters < 1000 { return ("\(Int((meters / 10).rounded()) * 10)", "m") }
        return ((meters / 1000).formatted(.number.precision(.fractionLength(1))), "km")
    }

    static func symbol(for instruction: VisualInstruction?) -> String {
        guard let instruction else { return "arrow.up" }
        switch instruction.maneuverType {
        case .arrive: return "flag.checkered"
        case .takeRoundabout, .turnAtRoundabout, .takeRotary, .exitRoundabout, .exitRotary:
            return "arrow.triangle.turn.up.right.circle"
        default: break
        }
        switch instruction.maneuverDirection {
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .uTurn: return "arrow.uturn.down"
        default: return "arrow.up"
        }
    }
}

/// Mapbox's `NavigationMapView`, styled like Streetnav's map: Standard in colour, light of the hour, French labels,
/// the route in the app's single blue.
private struct StreetnavGuidanceMap: UIViewRepresentable {
    @ObservedObject var guidance: StreetnavGuidance
    let light: StandardLightPreset

    final class Coordinator {
        var shownRoute: String?
        var light: StandardLightPreset?
        var styleObserver: AnyCancelable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NavigationMapView {
        let view = NavigationMapView(location: guidance.$location.compactMap { $0 }.eraseToAnyPublisher(),
                                     routeProgress: guidance.$progress.eraseToAnyPublisher(),
                                     routeRefreshing: guidance.routeRefreshing)
        view.mapView.mapboxMap.mapStyle = Self.style(light)
        context.coordinator.light = light
        context.coordinator.styleObserver = view.mapView.mapboxMap.onStyleLoaded.observe { [weak view] _ in
            try? view?.mapView.mapboxMap.localizeLabels(into: Locale(identifier: "fr"))
        }
        view.routeColor = .systemBlue
        view.routeCasingColor = UIColor(white: 1, alpha: 0.9)
        view.traversedRouteColor = UIColor(white: 0.55, alpha: 0.5)
        view.showsTrafficOnRouteLine = false
        view.showsAlternatives = false
        // Clear of the manoeuvre card at the top and the ride card at the bottom.
        view.viewportPadding = UIEdgeInsets(top: 150, left: 40, bottom: 140, right: 40)
        view.mapView.ornaments.options.scaleBar.visibility = .hidden
        view.mapView.ornaments.options.compass.visibility = .hidden
        view.mapView.ornaments.options.logo.margins = CGPoint(x: 16, y: 104)
        view.mapView.ornaments.options.attributionButton.margins = CGPoint(x: 100, y: 102)
        view.update(navigationCameraState: .following)
        show(guidance.routes, in: view, context: context)
        return view
    }

    func updateUIView(_ view: NavigationMapView, context: Context) {
        show(guidance.routes, in: view, context: context)
        if context.coordinator.light != light {
            view.mapView.mapboxMap.mapStyle = Self.style(light)
            context.coordinator.light = light
        }
    }

    private func show(_ routes: NavigationRoutes?, in view: NavigationMapView, context: Context) {
        guard let routes else { return }
        let id = "\(routes.mainRoute.routeId)"
        guard context.coordinator.shownRoute != id else { return }
        context.coordinator.shownRoute = id
        view.show(routes, routeAnnotationKinds: [])
    }

    private static func style(_ light: StandardLightPreset) -> MapStyle {
        .standard(theme: .default, lightPreset: light, showPointOfInterestLabels: false, showTransitLabels: false,
                  showPlaceLabels: true, showRoadLabels: true, showPedestrianRoads: true, show3dObjects: true)
    }
}
