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
    @ObservedObject private var history = StreetnavRideHistory.shared
    @ObservedObject private var live = StreetnavLiveStreets.shared
    @AppStorage(StreetnavStreetFilter.key) private var streetFilter: StreetnavStreetFilter = .all
    @AppStorage(StreetnavMapZoom.key) private var zoomOffset = 0.0
    @Environment(\.colorScheme) private var colorScheme
    @State private var sunLight = StreetnavSunlight.preset(at: .now)
    @State private var showsOverview = false
    @State private var showsEnd = false

    var body: some View {
        StreetnavGuidanceMap(guidance: guidance, light: colorScheme == .dark ? .night : sunLight, showsOverview: showsOverview,
                             streets: history.streets, live: live.ridden, outside: history.tracksOutside, filter: streetFilter,
                             dark: colorScheme == .dark,
                             zoomOffset: zoomOffset)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if guidance.hasArrived == false {
                    // Measured on Maps (iOS 27): card 8 points from the sides, round buttons 16 from the edge, 11 below it.
                    VStack(alignment: .trailing, spacing: 11) {
                        maneuverCard
                        roundButton(showsOverview ? "location.north.line.fill" : "point.topleft.down.to.point.bottomright.curvepath",
                                    label: showsOverview ? "Suivre ma position" : "Voir tout l'itinéraire") {
                            showsOverview.toggle()
                        }
                        .padding(.trailing, 8)
                        if showsOverview == false {
                            zoomButtons
                                .padding(.trailing, 8)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                // Down to the bottom edge, as in Maps: 8 points from the sides and 11 from the bottom of the screen.
                VStack(spacing: 9) {
                    if guidance.hasArrived {
                        arrivalCard
                    } else {
                        if let street = currentStreet {
                            Text(street)
                                .font(.headline)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .streetnavGlass(in: Capsule())
                                .transition(.opacity)
                        }
                        tripCard
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 11)
                .ignoresSafeArea(edges: .bottom)
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
                .font(.system(size: 48, weight: .bold))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(stepDistance)
                    .font(.system(size: 31, weight: .bold))
                    .monospacedDigit()
                Text(guidance.instruction?.primaryInstruction.text ?? "Calcul de l'itinéraire…")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    /// Arrival, time and distance left; pulled up (or tapped), it offers to end the route, as in Maps.
    private var tripCard: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
            HStack(spacing: 0) {
                tripValue(arrivalTime, "arrivée")
                tripValue(remainingTime.value, remainingTime.unit)
                tripValue(remainingDistance.value, remainingDistance.unit)
            }
            .padding(.horizontal, 10)
            .padding(.top, 22)
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
                .padding(.top, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, 7)
        .padding(.horizontal, 20)
        // Clear of the home indicator, which the card covers.
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 48, style: .continuous))
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
                .font(.system(size: 27, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 17))
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
        .padding(.top, 22)
        .padding(.horizontal, 22)
        .padding(.bottom, 26)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 48, style: .continuous))
    }

    /// Closer or farther, as in Waze: the camera still frames the turns ahead, a step closer or farther than before, and
    /// the exploration map follows the rider at that distance too.
    private var zoomButtons: some View {
        VStack(spacing: 0) {
            Button { zoomOffset = StreetnavMapZoom.clamped(zoomOffset + StreetnavMapZoom.step) } label: {
                Image(systemName: "plus")
                    .frame(width: 60, height: 56)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Zoomer")
            Button { zoomOffset = StreetnavMapZoom.clamped(zoomOffset - StreetnavMapZoom.step) } label: {
                Image(systemName: "minus")
                    .frame(width: 60, height: 56)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dézoomer")
        }
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.primary)
        .streetnavGlass(in: Capsule(), interactive: true)
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
    /// The streets ridden or not, drawn under the route as on the exploration map, with its choice of which.
    let streets: String?
    /// The streets this ride has just turned blue (StreetnavLiveStreets), above those still to ride.
    let live: String?
    /// The rides beyond Paris and the inner suburbs, drawn like the streets ridden.
    let outside: String?
    let filter: StreetnavStreetFilter
    let dark: Bool
    /// StreetnavMapZoom's offset: the following camera's zoom bounds move by it.
    let zoomOffset: Double

    final class Coordinator {
        var shownRoute: String?
        var light: StandardLightPreset?
        var styleObserver: AnyCancelable?
        var showsOverview = false
        var streets: String?
        /// The light the streets behind the buildings were blended for.
        var streetsLight: StandardLightPreset?
        var live: String?
        var outside: String?
        var filter = StreetnavStreetFilter.all
        var dark = false
        var zoomOffset: Double?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NavigationMapView {
        let view = NavigationMapView(location: guidance.$location.compactMap { $0 }.eraseToAnyPublisher(),
                                     routeProgress: guidance.$progress.eraseToAnyPublisher(),
                                     routeRefreshing: guidance.routeRefreshing)
        view.mapView.mapboxMap.mapStyle = Self.style(light)
        context.coordinator.light = light
        context.coordinator.styleObserver = view.mapView.mapboxMap.onStyleLoaded.observe { [weak view, weak coordinator = context.coordinator] _ in
            guard let map = view?.mapView.mapboxMap, let coordinator else { return }
            try? map.localizeLabels(into: Locale(identifier: "fr"))
            // The relief of the exploration map.
            try? map.addSource(StreetnavExplorationMap.reliefSource)
            try? map.setTerrain(Terrain(sourceId: "relief").exaggeration(StreetnavExplorationMap.reliefExaggeration))
            // A new style has none of them.
            Self.show(streets: coordinator.streets, live: coordinator.live, outside: coordinator.outside, filter: coordinator.filter,
                      dark: coordinator.dark,
                      light: coordinator.light ?? .day, in: map, reload: true)
        }
        context.coordinator.streets = streets
        context.coordinator.live = live
        context.coordinator.outside = outside
        context.coordinator.filter = filter
        context.coordinator.dark = dark
        view.routeColor = .systemBlue
        view.routeCasingColor = UIColor(white: 1, alpha: 0.9)
        view.traversedRouteColor = UIColor(white: 0.55, alpha: 0.5)
        view.showsTrafficOnRouteLine = false
        view.showsAlternatives = false
        // Clear of the manoeuvre card at the top and the trip card at the bottom.
        view.viewportPadding = UIEdgeInsets(top: 230, left: 40, bottom: 170, right: 40)
        view.mapView.ornaments.options.scaleBar.visibility = .hidden
        view.mapView.ornaments.options.compass.visibility = .hidden
        // Above the street being ridden.
        view.mapView.ornaments.options.logo.margins = CGPoint(x: 16, y: 142)
        view.mapView.ornaments.options.attributionButton.position = .bottomLeading
        view.mapView.ornaments.options.attributionButton.margins = CGPoint(x: 100, y: 140)
        Self.follow(at: zoomOffset, in: view)
        context.coordinator.zoomOffset = zoomOffset
        view.update(navigationCameraState: .following)
        show(guidance.routes, in: view, context: context)
        return view
    }

    func updateUIView(_ view: NavigationMapView, context: Context) {
        show(guidance.routes, in: view, context: context)
        if context.coordinator.zoomOffset != zoomOffset {
            context.coordinator.zoomOffset = zoomOffset
            Self.follow(at: zoomOffset, in: view)
        }
        if context.coordinator.showsOverview != showsOverview {
            context.coordinator.showsOverview = showsOverview
            view.update(navigationCameraState: showsOverview ? .overview : .following)
        }
        if context.coordinator.light != light {
            view.mapView.mapboxMap.mapStyle = Self.style(light)
            context.coordinator.light = light
        }
        let coordinator = context.coordinator
        if coordinator.streets != streets || coordinator.live != live || coordinator.outside != outside || coordinator.filter != filter
            || coordinator.dark != dark
            || coordinator.streetsLight != light {
            let relayer = coordinator.filter != filter || coordinator.dark != dark || coordinator.streetsLight != light
            coordinator.streetsLight = light
            coordinator.streets = streets
            coordinator.live = live
            coordinator.outside = outside
            coordinator.filter = filter
            coordinator.dark = dark
            if view.mapView.mapboxMap.isStyleLoaded {
                Self.show(streets: streets, live: live, outside: outside, filter: filter, dark: dark, light: light, in: view.mapView.mapboxMap,
                          reload: relayer)
            }
        }
    }

    /// Lines drawn like the streets ridden (this ride's, the rides beyond the zones), just above the streets layers
    /// (behind the buildings, then in sight).
    private static func show(ridden geojson: String?, source: String, filter: StreetnavStreetFilter, dark: Bool,
                             light: StandardLightPreset, in map: MapboxMap, reload: Bool) {
        let shown = geojson != nil && filter.showsRidden
        let layers = [StreetnavExplorationMap.streetsRidden(dark: dark, behind: light, id: source + "-derriere", source: source),
                      StreetnavExplorationMap.streetsRidden(dark: dark, id: source, source: source)]
        for layer in layers where reload || shown == false {
            if map.layerExists(withId: layer.id) { try? map.removeLayer(withId: layer.id) }
        }
        guard let geojson, shown else { return }
        if map.sourceExists(withId: source) {
            map.updateGeoJSONSource(withId: source, data: .string(geojson))
        } else {
            try? map.addSource(StreetnavExplorationMap.geoJSONSource(source, geojson))
        }
        var above = ["rues-faites", "rues-jamais"].first { map.layerExists(withId: $0) }
        for layer in layers {
            if map.layerExists(withId: layer.id) == false {
                try? map.addLayer(layer, layerPosition: above.map { .above($0) } ?? .at(0))
            }
            above = layer.id
        }
    }

    /// The camera keeps choosing its zoom to frame the turns ahead, between the SDK's bounds moved by the offset.
    private static func follow(at zoomOffset: Double, in view: NavigationMapView) {
        guard let source = view.navigationCamera.viewportDataSource as? MobileViewportDataSource else { return }
        let bounds = FollowingCameraOptions().zoomRange
        source.options.followingCameraOptions.zoomRange = (bounds.lowerBound + zoomOffset)...(bounds.upperBound + zoomOffset)
    }

    /// The streets source and the layers the filter keeps, first of the layers added to the style so that they lie under
    /// the route (same slot); `reload` draws the layers again, for another filter or the other mode's colours.
    private static func show(streets: String?, live: String?, outside: String?, filter: StreetnavStreetFilter, dark: Bool,
                             light: StandardLightPreset, in map: MapboxMap, reload: Bool) {
        defer {
            show(ridden: outside, source: "sorties-ailleurs", filter: filter, dark: dark, light: light, in: map, reload: reload)
            show(ridden: live, source: "rues-direct", filter: filter, dark: dark, light: light, in: map, reload: reload)
        }
        guard let streets else { return }
        if map.sourceExists(withId: "rues-osm") {
            map.updateGeoJSONSource(withId: "rues-osm", data: .string(streets))
        } else {
            try? map.addSource(StreetnavExplorationMap.streetsLayerSource(streets))
        }
        // Inserted at the bottom one after the other, from the top: both colours behind the buildings, then both in sight,
        // the streets ridden above those still to ride each time.
        let layers = [(StreetnavExplorationMap.streetsRidden(dark: dark), filter.showsRidden),
                      (StreetnavExplorationMap.streetsNotRidden(dark: dark), filter.showsNotRidden),
                      (StreetnavExplorationMap.streetsRidden(dark: dark, behind: light), filter.showsRidden),
                      (StreetnavExplorationMap.streetsNotRidden(dark: dark, behind: light), filter.showsNotRidden)]
        for (layer, shown) in layers {
            if reload || shown == false, map.layerExists(withId: layer.id) { try? map.removeLayer(withId: layer.id) }
            if shown, map.layerExists(withId: layer.id) == false { try? map.addLayer(layer, layerPosition: .at(0)) }
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
        StreetnavExplorationMap.standardStyle(light: light)
    }
}
