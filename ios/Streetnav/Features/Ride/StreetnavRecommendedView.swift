import MapboxMaps
import SwiftUI

@MainActor
struct StreetnavRecommendedView: View {
    @StateObject private var model: StreetnavPrototypeViewModel
    @StateObject private var places = StreetnavPlaceSearch()
    @ObservedObject private var history = StreetnavRideHistory.shared
    @ObservedObject private var live = StreetnavLiveStreets.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSheet: StreetnavSheet?
    @State private var showsEndConfirmation = false
    /// Paris until the first position comes in (or if it is refused), rather than the whole globe.
    @State private var viewport = Viewport.camera(center: StreetnavMockData.parisCenter, zoom: 12.5).padding(.bottom, 292)
    @State private var panelDetent = StreetnavExplorePanel.preferredDetent(for: .home)
    @State private var isThreeD = true
    /// Top of the panel and bottom of the safe area, in screen points, followed while the panel is dragged.
    @State private var panelTop: CGFloat?
    @State private var safeAreaBottom: CGFloat = 0
    private let embedded: Bool

    init(embedded: Bool = false) {
        _model = StateObject(wrappedValue: StreetnavPrototypeViewModel())
        self.embedded = embedded
    }

    init(model: StreetnavPrototypeViewModel, embedded: Bool = false) {
        _model = StateObject(wrappedValue: model)
        self.embedded = embedded
    }

    var body: some View {
        ZStack {
            StreetnavExplorationMap(
                // Which streets were ridden is not computed yet: the rides' tracks show where the rider has been.
                segments: [],
                route: model.flowState == .home || model.flowState == .planner ? nil : model.route,
                mode: model.flowState,
                place: model.flowState == .home ? places.place : nil,
                placeRoute: model.flowState == .home ? places.route?.coordinates : nil,
                placeAlternatives: model.flowState == .home
                    ? places.routes.filter { $0.kind != places.route?.kind }.map(\.coordinates) : [],
                rides: history.tracks,
                streets: history.streets,
                live: live.ridden,
                outside: history.tracksOutside,
                routeProgress: model.flowState.isNavigationLike ? model.rideProgress.routeProgress : 0,
                panelOverlap: panelTop.map { max(0, safeAreaBottom - $0) } ?? cameraInset,
                viewport: $viewport,
                isThreeD: $isThreeD,
                recenter: locationTapped,
                choosePoint: model.flowState == .home
                    ? { coordinate, building in Task { await places.choose(pointAt: coordinate, building: building) } } : nil
            )

            switch model.flowState {
            case .navigating, .approachingNewStreet, .completedNewStreet, .rerouting, .weakGPS, .paused:
                navigationOverlay
            case .arrived:
                arrivalOverlay
            case .home, .planner, .routePreview, .readiness:
                if embedded { embeddedPanel }
            }
        }
        // The bike, as Maps shows the weather: top left, while exploring.
        .overlay(alignment: .topLeading) {
            if [.home, .planner, .routePreview, .readiness].contains(model.flowState), panelDetent != .large {
                StreetnavBikeChip()
                    .padding(.leading, 16)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { safeAreaBottom = $0 }
        .task {
            recenter()
            await model.load()
        }
        // The tracks and statistics from the server, whenever the app comes back to the front.
        .task { await history.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await history.refresh() }
        }
        .sheet(isPresented: panelIsPresented) {
            StreetnavExplorePanel(model: model, places: places, presentedSheet: $presentedSheet, detent: $panelDetent, focus: focus(on:))
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { panelTop = $0 }
                .presentationDetents(StreetnavExplorePanel.detents(for: model.flowState, place: places.place != nil),
                                     selection: $panelDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: StreetnavExplorePanel.preferredDetent(for: model.flowState)))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.flowState) { oldState, newState in
            flowChanged(from: oldState, to: newState)
        }
        .onChange(of: isThreeD) { recenter() }
        .onChange(of: panelDetent) {
            // Still following the rider, the same way (north up or turning with the phone), with the new room.
            guard viewport.followPuck != nil else { return }
            withViewportAnimation(.default(maxDuration: 0.4)) {
                viewport = viewport.padding(.bottom, cameraInset)
            }
        }
        .onChange(of: places.place) { _, place in
            guard let place else { return recenter() }
            // Tall enough for the ways there and the button to leave.
            panelDetent = StreetnavExplorePanel.place
            withViewportAnimation(.default(maxDuration: 0.8)) {
                viewport = Viewport.camera(center: place.coordinate, zoom: 16, pitch: 50).padding(.bottom, cameraInset)
            }
        }
        // Every way there in sight, as each comes.
        .onChange(of: places.routes) { _, routes in
            guard routes.isEmpty == false else { return }
            withViewportAnimation(.easeInOut(duration: 0.8)) {
                viewport = StreetnavExplorationMap.focus(on: routes.flatMap(\.coordinates), padding: 50, bottomInset: cameraInset)
            }
        }
        .onChange(of: model.route.id) {
            guard model.flowState.isRouteStep else { return }
            withViewportAnimation(.easeInOut(duration: 0.6)) {
                viewport = StreetnavExplorationMap.viewport(for: model.flowState, route: model.route, bottomInset: cameraInset, pitch: isThreeD ? StreetnavMapTilt.pitch(50) : 0)
            }
        }
        .alert("Terminer la sortie ?", isPresented: $showsEndConfirmation) {
            Button("Continuer", role: .cancel) {}
            Button("Terminer", role: .destructive) { model.finishRide() }
        } message: {
            Text("La navigation s'arrêtera et Streetnav préparera le résumé de la sortie.")
        }
        .animation(StreetnavMotion.spring(model.tuning, reduceMotion: reduceMotion || model.tuning.simulateReducedMotion), value: model.flowState)
    }

    /// The panel stays up, like the card in Maps, everywhere but during the ride and its summary.
    private var panelIsPresented: Binding<Bool> {
        Binding(
            get: { embedded == false && (model.flowState == .home || model.flowState == .planner || model.flowState.isRouteStep) },
            set: { _ in }
        )
    }

    private var embeddedPanel: some View {
        VStack {
            Spacer()
            StreetnavExplorePanel(model: model, places: places, presentedSheet: $presentedSheet, detent: $panelDetent, embedded: true, focus: focus(on:))
                .streetnavGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    /// What the camera keeps clear at the bottom: the panel where it rests (only the search bar once folded, its height
    /// for the step otherwise), or the arrival card. It does not follow the panel while it is dragged, so the map stays
    /// still, as in Maps: the rider comes back to the middle of the map left once the panel settles.
    private var cameraInset: CGFloat {
        if model.flowState == .arrived { return 430 }
        if model.flowState.isNavigationLike { return 0 }
        if embedded { return 300 }
        if panelDetent == StreetnavExplorePanel.collapsed { return 76 }
        if panelDetent == StreetnavExplorePanel.place { return 440 }
        switch model.flowState {
        case .routePreview: return 452
        case .readiness: return 386
        case .home: return 292
        default: return 292
        }
    }

    private func flowChanged(from oldState: PrototypeFlowState, to newState: PrototypeFlowState) {
        if newState == .routePreview, presentedSheet == .planner { presentedSheet = nil }
        let preferred = StreetnavExplorePanel.preferredDetent(for: newState)
        if preferred != StreetnavExplorePanel.preferredDetent(for: oldState) { panelDetent = preferred }
        // The default animation is the one that keeps up with a moving position.
        withViewportAnimation(.default(maxDuration: 0.8)) {
            viewport = StreetnavExplorationMap.viewport(for: newState, route: model.route, bottomInset: cameraInset, pitch: isThreeD ? StreetnavMapTilt.pitch(50) : 0)
        }
    }

    private func recenter() {
        withViewportAnimation(.default(maxDuration: 0.5)) {
            viewport = StreetnavExplorationMap.viewport(for: model.flowState, route: model.route, bottomInset: cameraInset, pitch: isThreeD ? StreetnavMapTilt.pitch(50) : 0)
        }
    }

    /// The location button, as in Maps: back to the rider and following them; tapped again, closer, tilted and turning
    /// with where the phone points; once more, north up again.
    private func locationTapped() {
        let exploring = model.flowState == .home || model.flowState == .planner
        guard exploring, let following = viewport.followPuck, following.bearing != .heading else { return recenter() }
        withViewportAnimation(.default(maxDuration: 0.6)) {
            viewport = StreetnavExplorationMap.headingViewport(bottomInset: cameraInset)
        }
    }

    private func focus(on coordinates: [CLLocationCoordinate2D]) {
        if panelDetent == .large { panelDetent = StreetnavExplorePanel.preferredDetent(for: model.flowState) }
        withViewportAnimation(.easeInOut(duration: 0.6)) {
            viewport = StreetnavExplorationMap.focus(on: coordinates, bottomInset: cameraInset)
        }
    }

    // MARK: Ride

    private var navigationOverlay: some View {
        let instruction = model.route.instructions[safe: model.rideProgress.currentInstructionIndex] ?? model.route.instructions[0]
        let paused = model.flowState == .paused
        return VStack(spacing: 10) {
            if paused {
                Label("Navigation en pause", systemImage: "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .streetnavGlass(in: Capsule())
                    .padding(.top, 8)
            } else {
                maneuverBanner(instruction)
                HStack(alignment: .top) {
                    if model.showsCompletionToast {
                        discoveryToast(street: instruction.streetName)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        glassButton(model.audioGuidanceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", label: "Guidage vocal") {
                            model.audioGuidanceEnabled.toggle()
                        }
                        glassButton("location.fill", label: "Recentrer", action: recenter)
                    }
                }
                .padding(.horizontal, 16)
            }

            if model.flowState == .rerouting {
                Label("Recalcul de l'itinéraire", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .streetnavGlass(in: Capsule())
            }

            Spacer()

            rideCard(paused: paused)
        }
    }

    /// The manoeuvre banner of Maps: symbol, distance in large type, street underneath.
    private func maneuverBanner(_ instruction: NavigationInstruction) -> some View {
        let weak = model.flowState == .weakGPS || model.gpsQuality == .weak
        return HStack(spacing: 16) {
            Image(systemName: instruction.symbolName)
                .font(.system(size: 38, weight: .semibold))
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(weak ? "Signal GPS faible" : instruction.distanceText.replacingOccurrences(of: "Dans ", with: ""))
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(instruction.streetName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(instruction.spokenLabel)
        #if DEBUG
        // Prototype: a tap on the banner simulates a street discovered.
        .onTapGesture { withAnimation(.snappy) { model.completeNewStreet() } }
        #endif
    }

    private func discoveryToast(street: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nouvelle rue découverte")
                    .font(.subheadline.weight(.semibold))
                Text("\(street) · +\(model.rideProgress.completedNewRoadMeters) m")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .streetnavGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The card at the bottom during the ride: arrival, time left, new streets, progress and the two actions.
    private func rideCard(paused: Bool) -> some View {
        let progress = model.rideProgress
        return VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            if paused {
                VStack(alignment: .leading, spacing: 2) {
                    Text("En pause")
                        .font(.title2.weight(.bold))
                    Text("\(model.route.name) · \(progress.remainingMinutes) min restantes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                StreetnavStat(label: "Arrivée", value: model.route.arrivalText)
                StreetnavStat(label: "Restant", value: "\(progress.remainingMinutes)", unit: "min")
                StreetnavStat(label: "Nouvelles", value: "\(progress.completedNewRoadMeters)", unit: "m")
            }
            ProgressView(value: progress.routeProgress)
                .accessibilityLabel("Progression de l'itinéraire")
            HStack(spacing: 12) {
                if paused {
                    Button { model.resumeRide() } label: {
                        Label("Reprendre", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button { model.pauseRide() } label: {
                        Label("Pause", systemImage: "pause.fill").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) { showsEndConfirmation = true } label: {
                    Text("Terminer").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .streetnavGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    // MARK: Arrival

    private var arrivalOverlay: some View {
        let summary = model.summary
        return VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sortie terminée")
                            .font(.title2.weight(.bold))
                        Text("\(model.route.name) · aujourd'hui, \(model.route.arrivalText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    glassButton("xmark", label: "Fermer") { model.flowState = .home }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow {
                        StreetnavStat(label: "Distance", value: kilometers(summary.distanceKilometers), unit: "km")
                        StreetnavStat(label: "Durée", value: "\(summary.durationMinutes)", unit: "min")
                        StreetnavStat(label: "Nouvelles", value: kilometers(summary.newRoadKilometers), unit: "km")
                    }
                    GridRow {
                        StreetnavStat(label: "Découverte", value: "\(Int(summary.discoveryShare * 100))", unit: "%")
                        StreetnavStat(label: "FC moyenne", value: summary.heartRateAverage.map(String.init) ?? "—", unit: "bpm")
                        StreetnavStat(label: "Énergie", value: summary.calories.map(String.init) ?? "—", unit: "kcal")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.area.name)
                            .font(.headline)
                        Spacer()
                        Text("\(Int(summary.areaCompletionBefore * 100)) % → \(Int(summary.areaCompletionAfter * 100)) %")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: summary.areaCompletionAfter)
                }
                .accessibilityElement(children: .combine)
                Label("Enregistrée sur ton serveur Streetnav", systemImage: "checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ShareLink(item: "\(model.route.name) : \(kilometers(summary.distanceKilometers)) km, dont \(kilometers(summary.newRoadKilometers)) km de rues nouvelles.") {
                        Label("Partager", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { model.flowState = .home } label: {
                        Text("Terminé").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 20)
            .streetnavGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }

    private func kilometers(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

/// « Explorer »: how long, what kind of loop, which streets to avoid.
struct StreetnavPlannerSheet: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @Environment(\.dismiss) private var dismiss
    private let durations = [30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            Form {
                Section("Durée") {
                    Picker("Durée", selection: $model.selectedDuration) {
                        ForEach(durations, id: \.self) { duration in
                            Text("\(duration) min").tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Stepper(value: $model.selectedDuration, in: 20...120, step: 5) {
                        LabeledContent("Personnalisée", value: "\(model.selectedDuration) min")
                    }
                }

                Section("Parcours") {
                    Picker("Priorité", selection: $model.plannerPriority) {
                        ForEach(PlannerPriority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                    Toggle("Boucle avec retour au départ", isOn: .constant(true))
                    Toggle("Destination précise", isOn: $model.destinationMode)
                }

                Section("Options avancées") {
                    Toggle("Préférer les pistes protégées", isOn: $model.preferProtectedCycleways)
                    Toggle("Éviter les carrefours difficiles", isOn: $model.avoidDifficultIntersections)
                    Toggle("Éviter les pavés", isOn: $model.avoidCobblestones)
                    Toggle("Limiter les rues répétées", isOn: $model.minimizeRepeatedRoads)
                }

                if let routeErrorMessage = model.routeErrorMessage {
                    Section {
                        Text(routeErrorMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fermer")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { model.planRoute() } label: {
                    Group {
                        if model.isPlanningRoute {
                            ProgressView()
                        } else {
                            Text("Calculer l'itinéraire")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(model.isPlanningRoute)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }
}

/// « Réglages »: the Streetnav server first (it is the source of truth), then Apple Health, the Watch and the bike.
struct StreetnavIntegrationSheet: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @ObservedObject private var healthSync = StreetnavHealthSync.shared
    @ObservedObject private var vanMoof = StreetnavVanMoofAccount.shared
    @ObservedObject private var vanMoofBike = StreetnavVanMoofBike.shared
    @Environment(\.dismiss) private var dismiss
    @State private var activityCount: Int?
    @State private var serverError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        StreetnavServerSettingsView()
                    } label: {
                        StreetnavSettingsRow(symbol: "server.rack", title: "Serveur Streetnav", detail: serverDetail)
                    }
                    StreetnavSettingsRow(symbol: "list.bullet", title: "Activités en base", value: activityCount?.formatted() ?? "—")
                } header: {
                    header("Serveur Streetnav")
                } footer: {
                    Text("Ta base PostgreSQL à la maison fait foi pour toutes tes sorties.")
                }

                Section {
                    NavigationLink {
                        StreetnavHealthSyncView()
                    } label: {
                        StreetnavSettingsRow(symbol: "heart.fill", title: "Synchronisation", value: healthText)
                    }
                } header: {
                    header("Apple Santé")
                }

                Section {
                    StreetnavSettingsRow(symbol: "applewatch", title: model.watch.name, value: model.watch.state == .ready ? "Prête" : "Indisponible")
                    StreetnavSettingsRow(symbol: "heart.text.square", title: "Fréquence cardiaque", value: model.watch.heartRateAvailable ? "Disponible" : "Indisponible")
                } header: {
                    header("Apple Watch")
                }

                Section {
                    NavigationLink {
                        StreetnavVanMoofView()
                    } label: {
                        StreetnavSettingsRow(symbol: "bicycle", title: vanMoof.bike?.name ?? "VanMoof S6", value: bikeText)
                    }
                } header: {
                    header("Vélo")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fermer")
                }
            }
            .task { await loadActivityCount() }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var bikeText: String {
        guard vanMoof.isSignedIn else { return "À connecter" }
        if vanMoofBike.state == .ready, let battery = vanMoofBike.battery { return "\(battery) %" }
        return vanMoofBike.state == .ready ? "Connecté" : "Prêt"
    }

    private var serverDetail: String {
        guard let url = StreetnavServerSettings.baseURL, let host = url.host() else { return "À configurer" }
        let address = url.port.map { "\(host):\($0)" } ?? host
        if serverError { return "\(address) · injoignable" }
        return activityCount == nil ? address : "\(address) · connecté"
    }

    private var healthText: String {
        if healthSync.isSyncing { return "Synchro…" }
        if healthSync.lastError != nil { return "Erreur" }
        return healthSync.lastSync == nil ? "À configurer" : "À jour"
    }

    private func loadActivityCount() async {
        guard let client = StreetnavServerSettings.client else { return }
        do {
            activityCount = try await client.activityCount()
        } catch {
            serverError = true
        }
    }
}

/// « Détail du parcours »: surface, relief and the turn-by-turn list.
struct StreetnavRouteDetailsSheet: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let route = model.route
        NavigationStack {
            List {
                Section("Surface") {
                    LabeledContent("Pistes cyclables", value: route.surface.cycleway.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("Rues calmes", value: route.surface.calmStreets.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("Routes partagées", value: route.surface.sharedRoads.formatted(.percent.precision(.fractionLength(0))))
                }
                Section("Relief") {
                    StreetnavSettingsRow(symbol: "mountain.2", title: "Dénivelé positif", value: "\(route.elevationGainMeters) m")
                }
                Section("Instructions") {
                    ForEach(route.instructions) { instruction in
                        StreetnavSettingsRow(symbol: instruction.symbolName, title: instruction.maneuver, detail: instruction.streetName,
                                             value: instruction.distanceText.replacingOccurrences(of: "Dans ", with: ""))
                    }
                    StreetnavSettingsRow(symbol: "flag.checkered", title: "Arrivée", detail: route.returnsHome ? "Point de départ" : "Destination",
                                         value: "\(route.distanceKilometers.formatted(.number.precision(.fractionLength(1)))) km")
                }
            }
            .navigationTitle("Détail du parcours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fermer")
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
