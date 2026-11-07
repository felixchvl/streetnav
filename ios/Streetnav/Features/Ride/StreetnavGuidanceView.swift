import Combine
import MapboxDirections
@_spi(Experimental) import MapboxMaps
import MapboxNavigationCore
import SwiftUI

/// The ride to a place, laid out like Maps: Mapbox's navigation map (position snapped to the street, camera that
/// anticipates the turns, route that fades behind the rider, arrows at the turns) under a dark manoeuvre card, the
/// street being ridden and the trip card, which slides up to end the route. The camera and Mapbox's logo keep clear of
/// the cards, however tall they are.
struct StreetnavGuidanceView: View {
    @ObservedObject private var guidance = StreetnavGuidance.shared
    @ObservedObject private var history = StreetnavRideHistory.shared
    @ObservedObject private var live = StreetnavLiveStreets.shared
    @AppStorage(StreetnavStreetFilter.key) private var streetFilter: StreetnavStreetFilter = .all
    @AppStorage(StreetnavMapZoom.key) private var zoomOffset = 0.0
    @AppStorage(StreetnavMapTilt.key) private var tiltOffset = 0.0
    @Environment(\.colorScheme) private var colorScheme
    @State private var sunLight = StreetnavSunlight.preset(at: .now)
    @State private var showsOverview = false
    @State private var showsEnd = false
    /// The overview, zoom and tilt buttons: a tap on the map hides them, another brings them back; moving the map by hand
    /// sets them aside too, until it has been still for a moment.
    @State private var showsButtons = true
    @State private var buttonsReturn: Task<Void, Never>?
    /// The map moved by hand no longer follows the rider: the first button brings it back.
    @State private var movedByHand = false
    @State private var recenters = 0
    /// Where the cards lie within the safe area, and its height: the map keeps clear of them.
    @State private var safeHeight: CGFloat = 0
    @State private var maneuverFrame = CGRect.zero
    @State private var bottomFrame = CGRect.zero

    /// Measured on Maps (iOS 27): cards 8 points from the edges, round buttons 16, 11 points between them.
    private static let margin: CGFloat = 8
    private static let spacing: CGFloat = 11

    var body: some View {
        StreetnavGuidanceMap(guidance: guidance, light: StreetnavExplorationMap.light(dark: colorScheme == .dark, sun: sunLight),
                             showsOverview: showsOverview,
                             streets: history.streets, live: live.ridden, outside: history.tracksOutside, filter: streetFilter,
                             dark: colorScheme == .dark, zoomOffset: zoomOffset, tiltOffset: tiltOffset, clearance: clearance,
                             recenters: recenters,
                             onTap: {
                                 buttonsReturn?.cancel()
                                 showsButtons.toggle()
                             },
                             onMove: mapMoved)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if guidance.hasArrived == false {
                    VStack(alignment: .trailing, spacing: Self.spacing) {
                        maneuverCard
                            .reportsFrame(to: $maneuverFrame)
                        if showsButtons {
                            mapButtons
                                .padding(.trailing, Self.margin)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                // Down to the bottom edge, as in Maps, 11 points from it.
                VStack(spacing: 9) {
                    if guidance.hasArrived {
                        arrivalCard
                    } else {
                        streetLabel
                        tripCard
                    }
                }
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.spacing)
                .reportsFrame(to: $bottomFrame)
                .ignoresSafeArea(edges: .bottom)
            }
            .animation(.snappy, value: guidance.hasArrived)
            .animation(.snappy, value: showsEnd)
            .animation(.easeInOut(duration: 0.2), value: showsButtons)
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { sunLight = StreetnavSunlight.preset(at: $0) }
            // The screen stays on during the ride, as in Maps.
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .task { await StreetnavVanMoofBike.shared.connectIfSignedIn() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .coordinateSpace(.named(Self.safeArea))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { safeHeight = $0 }
    }

    /// The safe area, where the cards are measured: Mapbox adds it to the camera's padding and to the logo's margins.
    fileprivate static let safeArea = "guidance"

    /// What the camera and Mapbox's logo keep clear of, within the safe area: the camera keeps 40 points from the
    /// manoeuvre card and from the street's name, the logo sits just above the street's name.
    private var clearance: StreetnavMapClearance {
        let bottom = max(0, safeHeight - bottomFrame.minY)
        return StreetnavMapClearance(padding: UIEdgeInsets(top: maneuverFrame.maxY + 40, left: 40, bottom: bottom + 40, right: 40),
                                     logo: CGPoint(x: 16, y: bottom + 8))
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

    /// The speed, the time and distance left, the battery; pulled up (or tapped), it offers to end the route, as in Maps.
    private var tripCard: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
            StreetnavRideDashboard(location: guidance.location, timeLeft: remainingTime, arrival: arrivalTime,
                                   distanceLeft: remainingDistance)
                .padding(.top, 12)
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

    /// Set aside while the map is moved by hand, back once it has been still for a moment.
    private func mapMoved(_ moving: Bool) {
        buttonsReturn?.cancel()
        if moving {
            movedByHand = true
            showsButtons = false
        } else {
            buttonsReturn = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard Task.isCancelled == false else { return }
                showsButtons = true
            }
        }
    }

    /// The overview (or back to the rider, once the map was moved by hand), then the zoom and the tilt while the camera
    /// follows the rider.
    private var mapButtons: some View {
        VStack(spacing: Self.spacing) {
            if movedByHand, showsOverview == false {
                roundButton("location.fill", label: "Recentrer") {
                    movedByHand = false
                    recenters += 1
                }
            } else {
                roundButton(showsOverview ? "location.north.line.fill" : "point.topleft.down.to.point.bottomright.curvepath",
                            label: showsOverview ? "Suivre ma position" : "Voir tout l'itinéraire") {
                    movedByHand = false
                    showsOverview.toggle()
                }
            }
            if showsOverview == false {
                zoomButtons
                tiltButtons
            }
        }
    }

    @ViewBuilder private var streetLabel: some View {
        if let street = currentStreet {
            Text(street)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .streetnavGlass(in: Capsule())
                .transition(.opacity)
        }
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

    /// More or less tilted, kept for the exploration map too.
    private var tiltButtons: some View {
        VStack(spacing: 0) {
            Button { tiltOffset = StreetnavMapTilt.clamped(tiltOffset + StreetnavMapTilt.step) } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 60, height: 50)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Incliner davantage")
            Button { tiltOffset = StreetnavMapTilt.clamped(tiltOffset - StreetnavMapTilt.step) } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 60, height: 50)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Redresser")
        }
        .font(.system(size: 20, weight: .semibold))
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
    /// StreetnavMapTilt's offset: added to the following camera's pitch.
    let tiltOffset: Double
    /// What the camera and Mapbox's logo keep clear of.
    let clearance: StreetnavMapClearance
    /// Bumped to follow the rider again (or show the whole route again) after the map was moved by hand.
    let recenters: Int
    /// A tap on the map (not a double tap, which zooms).
    let onTap: () -> Void
    /// The map starts (true) or stops (false) being moved by hand.
    let onMove: (Bool) -> Void

    final class Coordinator: NSObject, NavigationMapViewDelegate {
        var onTap: (() -> Void)?
        var onMove: ((Bool) -> Void)?
        var recenters = 0
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
        var tiltOffset: Double?
        var clearance: StreetnavMapClearance?

        /// The SDK's own single tap on the map, which waits for a double tap to fail: Mapbox's `onMapTap` never fires under it.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .recognized { onTap?() }
        }

        /// A pan, pinch, rotation or tilt by hand (the SDK then stops following the rider), not a single tap.
        func navigationMapViewUserDidStartInteraction(_ navigationMapView: NavigationMapView) {
            onMove?(true)
        }

        func navigationMapViewUserDidEndInteraction(_ navigationMapView: NavigationMapView) {
            onMove?(false)
        }

        /// The SDK's lines lie flat on the ground, where the buildings simply cover them, and fade with
        /// `line-depth-occlusion-factor`, which the map no longer applies: the route vanished behind the buildings.
        /// Lifted and seen through them as on the exploration map instead.
        func navigationMapView(_ navigationMapView: NavigationMapView, willAdd layer: Layer) -> Layer? {
            guard var line = layer as? LineLayer else { return layer }
            line.lineDepthOcclusionFactor = nil
            line.lineOcclusionOpacity = .constant(StreetnavExplorationMap.routeThroughBuildings)
            line.lineElevationReference = .constant(.ground)
            line.lineZOffset = .constant(StreetnavExplorationMap.routeLift)
            return line
        }
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
            try? map.setTerrain(Terrain(sourceId: "relief").exaggeration(1))
            // A new style has none of them.
            Self.show(streets: coordinator.streets, live: coordinator.live, outside: coordinator.outside, filter: coordinator.filter,
                      dark: coordinator.dark,
                      light: coordinator.light ?? .day, in: map, reload: true)
        }
        context.coordinator.onTap = onTap
        context.coordinator.onMove = onMove
        context.coordinator.recenters = recenters
        view.mapViewTapGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.tapped(_:)))
        context.coordinator.streets = streets
        context.coordinator.live = live
        context.coordinator.outside = outside
        context.coordinator.filter = filter
        context.coordinator.dark = dark
        view.delegate = context.coordinator
        Self.colourRoute(dark: dark, in: view)
        view.traversedRouteColor = UIColor(white: 0.55, alpha: 0.5)
        view.showsTrafficOnRouteLine = false
        view.showsAlternatives = false
        Self.keepClear(clearance, in: view)
        context.coordinator.clearance = clearance
        view.mapView.ornaments.options.scaleBar.visibility = .hidden
        view.mapView.ornaments.options.compass.visibility = .hidden
        // Above the street being ridden.
        view.mapView.ornaments.options.attributionButton.position = .bottomLeading
        Self.follow(at: zoomOffset, tilt: tiltOffset, in: view)
        context.coordinator.zoomOffset = zoomOffset
        context.coordinator.tiltOffset = tiltOffset
        view.update(navigationCameraState: .following)
        show(guidance.routes, in: view, context: context)
        return view
    }

    func updateUIView(_ view: NavigationMapView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onMove = onMove
        if context.coordinator.recenters != recenters {
            context.coordinator.recenters = recenters
            view.update(navigationCameraState: showsOverview ? .overview : .following)
        }
        show(guidance.routes, in: view, context: context)
        if context.coordinator.clearance != clearance {
            context.coordinator.clearance = clearance
            Self.keepClear(clearance, in: view)
        }
        if context.coordinator.zoomOffset != zoomOffset || context.coordinator.tiltOffset != tiltOffset {
            let zoomChange = zoomOffset - (context.coordinator.zoomOffset ?? zoomOffset)
            let tiltChange = tiltOffset - (context.coordinator.tiltOffset ?? tiltOffset)
            context.coordinator.zoomOffset = zoomOffset
            context.coordinator.tiltOffset = tiltOffset
            Self.follow(at: zoomOffset, tilt: tiltOffset, in: view)
            // At once, without waiting for the camera's next update, which comes with the next position.
            let state = view.mapView.mapboxMap.cameraState
            view.mapView.camera.ease(to: CameraOptions(zoom: state.zoom + zoomChange,
                                                       pitch: StreetnavMapTilt.pitch(state.pitch, offset: tiltChange)),
                                     duration: 0.18)
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
        if coordinator.dark != dark {
            // Applied when the route is drawn: drawn again.
            Self.colourRoute(dark: dark, in: view)
            coordinator.shownRoute = nil
            show(guidance.routes, in: view, context: context)
        }
        if coordinator.streets != streets || coordinator.live != live || coordinator.outside != outside || coordinator.filter != filter
            || coordinator.dark != dark
            || coordinator.streetsLight != light {
            let relayer = coordinator.filter != filter || coordinator.dark != dark || coordinator.streetsLight != light
            // The streets of the whole area (14 MB) cut again only when they change, not each time this ride turns one green.
            let newStreets = coordinator.streets != streets
            coordinator.streetsLight = light
            coordinator.streets = streets
            coordinator.live = live
            coordinator.outside = outside
            coordinator.filter = filter
            coordinator.dark = dark
            if view.mapView.mapboxMap.isStyleLoaded {
                Self.show(streets: streets, live: live, outside: outside, filter: filter, dark: dark, light: light, in: view.mapView.mapboxMap,
                          reload: relayer, newStreets: newStreets)
            }
        }
    }

    /// Lines drawn like the streets ridden (this ride's, the rides beyond the zones), just above the streets layers
    /// (behind the buildings, then in sight).
    private static func show(ridden geojson: String?, source: String, filter: StreetnavStreetFilter, dark: Bool,
                             light: StandardLightPreset, in map: MapboxMap, reload: Bool) {
        let shown = geojson != nil && filter.showsRidden
        let covering = source == StreetnavExplorationMap.liveSource
        let layers = [StreetnavExplorationMap.streetsRidden(dark: dark, behind: light, id: source + "-derriere", source: source,
                                                            covering: covering),
                      StreetnavExplorationMap.streetsRidden(dark: dark, id: source, source: source, covering: covering)]
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

    /// The route of the exploration map: its blue, its white edge, black at night.
    private static func colourRoute(dark: Bool, in view: NavigationMapView) {
        view.routeColor = StreetnavExplorationMap.accent(dark: dark)
        view.routeCasingColor = StreetnavExplorationMap.routeEdge(dark: dark)
    }

    /// The camera's padding, and Mapbox's logo with its credits button just after it.
    private static func keepClear(_ clearance: StreetnavMapClearance, in view: NavigationMapView) {
        view.viewportPadding = clearance.padding
        view.mapView.ornaments.options.logo.margins = clearance.logo
        view.mapView.ornaments.options.attributionButton.margins = CGPoint(x: clearance.logo.x + 84, y: clearance.logo.y - 2)
    }

    /// Standard's HD road markings again, just above the streets layers, which would hide them; the lines added later
    /// above the streets (this ride's) go between them.
    private static func showMarkings(in map: MapboxMap) {
        guard StreetnavExplorationMap.showsMarkings else { return }
        if map.sourceExists(withId: StreetnavHDMarkings.sourceID) == false {
            try? map.addSource(StreetnavExplorationMap.hdMarkingsSource)
        }
        let layers: [Layer] = StreetnavExplorationMap.hdMarkings.lines + StreetnavExplorationMap.hdMarkings.symbols
        var above = ["rues-faites", "rues-jamais"].first { map.layerExists(withId: $0) }
        for layer in layers {
            if map.layerExists(withId: layer.id) == false {
                try? map.addLayer(layer, layerPosition: above.map { .above($0) } ?? .at(0))
            }
            above = layer.id
        }
    }

    /// The camera keeps choosing its zoom to frame the turns ahead, between the SDK's bounds moved by the zoom offset, and
    /// tilts as usual plus the tilt offset.
    private static func follow(at zoomOffset: Double, tilt tiltOffset: Double, in view: NavigationMapView) {
        guard let source = view.navigationCamera.viewportDataSource as? MobileViewportDataSource else { return }
        let usual = FollowingCameraOptions()
        source.options.followingCameraOptions.zoomRange = (usual.zoomRange.lowerBound + zoomOffset)...(usual.zoomRange.upperBound + zoomOffset)
        source.options.followingCameraOptions.defaultPitch = StreetnavMapTilt.pitch(usual.defaultPitch, offset: tiltOffset)
    }

    /// The streets source and the layers the filter keeps, first of the layers added to the style so that they lie under
    /// the route (same slot); `reload` draws the layers again, for another filter or the other mode's colours.
    private static func show(streets: String?, live: String?, outside: String?, filter: StreetnavStreetFilter, dark: Bool,
                             light: StandardLightPreset, in map: MapboxMap, reload: Bool, newStreets: Bool = true) {
        defer {
            show(ridden: outside, source: "sorties-ailleurs", filter: filter, dark: dark, light: light, in: map, reload: reload)
            show(ridden: live, source: StreetnavExplorationMap.liveSource, filter: filter, dark: dark, light: light, in: map,
                 reload: reload)
            showMarkings(in: map)
        }
        guard let streets else { return }
        if map.sourceExists(withId: "rues-osm") {
            if newStreets { map.updateGeoJSONSource(withId: "rues-osm", data: .string(streets)) }
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

/// Where the map's camera and Mapbox's logo keep clear of the cards: the padding of the camera, the margins of the logo
/// from the bottom left corner, both within the safe area (Mapbox adds it).
struct StreetnavMapClearance: Equatable {
    var padding: UIEdgeInsets
    var logo: CGPoint
}

private extension View {
    /// Keeps `frame` up to date with where the view lies in the guidance's safe area.
    func reportsFrame(to frame: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(StreetnavGuidanceView.safeArea)) }) { frame.wrappedValue = $0 }
    }
}
