import Combine
import MapboxDirections
@_spi(Experimental) import MapboxMaps
import MapboxNavigationCore
import SwiftUI

/// The ride to a place, laid out like Maps: Mapbox's navigation map (position snapped to the street, camera that
/// anticipates the turns, route that fades behind the rider, arrows at the turns) under a dark manoeuvre card, the
/// street being ridden and a card with the arrival, which slides up to end the route.
struct StreetnavGuidanceView: View {
    @ObservedObject private var guidance = StreetnavGuidance.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var sunLight = StreetnavSunlight.preset(at: .now)
    @State private var showsOverview = false
    @State private var showsEnd = false

    var body: some View {
        StreetnavGuidanceMap(guidance: guidance, light: colorScheme == .dark ? .night : sunLight, showsOverview: showsOverview)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if guidance.hasArrived == false {
                    VStack(alignment: .trailing, spacing: 14) {
                        maneuverCard
                        roundButton(showsOverview ? "location.north.line.fill" : "point.topleft.down.to.point.bottomright.curvepath",
                                    label: showsOverview ? "Suivre ma position" : "Voir tout l'itinéraire") {
                            showsOverview.toggle()
                        }
                        .padding(.trailing, 6)
                    }
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    if guidance.hasArrived {
                        arrivalCard
                    } else {
                        if let street = currentStreet {
                            Text(street)
                                .font(.headline)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .streetnavGlass(in: Capsule())
                                .transition(.opacity)
                        }
                        tripCard
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            .animation(.snappy, value: guidance.hasArrived)
            .animation(.snappy, value: showsEnd)
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { sunLight = StreetnavSunlight.preset(at: $0) }
            // The screen stays on during the ride, as in Maps.
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Cards

    /// Dark in light and dark mode alike, like the one in Maps.
    private var maneuverCard: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: Self.symbol(for: guidance.instruction?.primaryInstruction))
                .font(.system(size: 52, weight: .bold))
                .frame(width: 70)
            VStack(alignment: .leading, spacing: 2) {
                Text(stepDistance)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                Text(guidance.instruction?.primaryInstruction.text ?? "Calcul de l'itinéraire…")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    /// Arrival, time and distance left; pulled up (or tapped), it offers to end the route, as in Maps.
    private var tripCard: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
            HStack(spacing: 0) {
                tripValue(arrivalTime, "arrivée")
                tripValue(remainingTime.value, remainingTime.unit)
                tripValue(remainingDistance.value, remainingDistance.unit)
            }
            if showsEnd {
                Button(role: .destructive) {
                    showsEnd = false
                    guidance.stop()
                } label: {
                    Text("Terminer l'itinéraire")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.red)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 20)
        .padding(.bottom, showsEnd ? 20 : 18)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { showsEnd.toggle() }
        .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
            if drag.translation.height < -20 { showsEnd = true }
            if drag.translation.height > 20 { showsEnd = false }
        })
    }

    private func tripValue(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var arrivalCard: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 34, weight: .semibold))
                Text("Arrivé")
                    .font(.title.weight(.bold))
                Text(guidance.destinationName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
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
        .padding(22)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 60, height: 60)
                .streetnavGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var currentStreet: String? {
        guard let names = guidance.progress?.currentLegProgress.currentStep.names, let name = names.first, name.isEmpty == false else {
            return nil
        }
        return name
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

    private var remainingTime: (value: String, unit: String) {
        guard let seconds = guidance.progress?.durationRemaining else { return ("—", "min") }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? ("\(minutes)", "min") : ("\(minutes / 60):\(String(format: "%02d", minutes % 60))", "h")
    }

    private var remainingDistance: (value: String, unit: String) {
        guard let meters = guidance.progress?.distanceRemaining else { return ("—", "km") }
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
    let showsOverview: Bool

    final class Coordinator {
        var shownRoute: String?
        var light: StandardLightPreset?
        var styleObserver: AnyCancelable?
        var showsOverview = false
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
        // Clear of the manoeuvre card at the top and the trip card at the bottom.
        view.viewportPadding = UIEdgeInsets(top: 230, left: 40, bottom: 190, right: 40)
        view.mapView.ornaments.options.scaleBar.visibility = .hidden
        view.mapView.ornaments.options.compass.visibility = .hidden
        view.mapView.ornaments.options.logo.margins = CGPoint(x: 16, y: 190)
        view.mapView.ornaments.options.attributionButton.position = .bottomLeading
        view.mapView.ornaments.options.attributionButton.margins = CGPoint(x: 100, y: 188)
        view.update(navigationCameraState: .following)
        show(guidance.routes, in: view, context: context)
        return view
    }

    func updateUIView(_ view: NavigationMapView, context: Context) {
        show(guidance.routes, in: view, context: context)
        if context.coordinator.showsOverview != showsOverview {
            context.coordinator.showsOverview = showsOverview
            view.update(navigationCameraState: showsOverview ? .overview : .following)
        }
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
