import MapboxMaps
import SwiftUI

@MainActor
struct StreetnavRecommendedView: View {
    @StateObject private var model: StreetnavPrototypeViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSheet: StreetnavSheet?
    @State private var showsEndConfirmation = false
    @State private var viewport = StreetnavExplorationMap.viewport(for: .home, route: nil, position: StreetnavMockData.parisCenter)
    @State private var panelDetent = StreetnavExplorePanel.summary
    private let embedded: Bool

    init(embedded: Bool = false) {
        _model = StateObject(wrappedValue: StreetnavPrototypeViewModel())
        self.embedded = embedded
    }

    init(model: StreetnavPrototypeViewModel, embedded: Bool = false) {
        _model = StateObject(wrappedValue: model)
        self.embedded = embedded
    }

    private var position: CLLocationCoordinate2D { StreetnavMockData.parisCenter }

    var body: some View {
        ZStack {
            StreetnavExplorationMap(
                segments: model.streets,
                route: model.flowState == .home || model.flowState == .planner ? nil : model.route,
                mode: model.flowState,
                position: position,
                routeProgress: model.flowState.isNavigationLike ? model.rideProgress.routeProgress : 0,
                bottomInset: mapBottomInset,
                viewport: $viewport,
                recenter: recenter
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
        .task { await model.load() }
        .sheet(isPresented: panelIsPresented) {
            StreetnavExplorePanel(model: model, presentedSheet: $presentedSheet, detent: $panelDetent, focus: focus(on:))
                .presentationDetents(StreetnavExplorePanel.detents(for: model.flowState), selection: $panelDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: StreetnavExplorePanel.preferredDetent(for: model.flowState)))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.flowState) { oldState, newState in
            flowChanged(from: oldState, to: newState)
        }
        .onChange(of: model.route.id) {
            guard model.flowState.isRouteStep else { return }
            withViewportAnimation(.easeInOut(duration: 0.6)) {
                viewport = StreetnavExplorationMap.viewport(for: model.flowState, route: model.route, position: position)
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
            StreetnavExplorePanel(model: model, presentedSheet: $presentedSheet, detent: $panelDetent, embedded: true, focus: focus(on:))
                .streetnavGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    /// Keeps what the camera frames above the panel.
    private var mapBottomInset: CGFloat {
        if embedded { return model.flowState.isNavigationLike || model.flowState == .arrived ? 0 : 300 }
        guard panelIsPresented.wrappedValue else { return 0 }
        switch panelDetent {
        case StreetnavExplorePanel.collapsed: return 92
        case StreetnavExplorePanel.route: return 346
        case StreetnavExplorePanel.readiness: return 396
        default: return 276
        }
    }

    private func flowChanged(from oldState: PrototypeFlowState, to newState: PrototypeFlowState) {
        if newState == .routePreview, presentedSheet == .planner { presentedSheet = nil }
        let preferred = StreetnavExplorePanel.preferredDetent(for: newState)
        if preferred != StreetnavExplorePanel.preferredDetent(for: oldState) { panelDetent = preferred }
        withViewportAnimation(.easeInOut(duration: 0.8)) {
            viewport = StreetnavExplorationMap.viewport(for: newState, route: model.route, position: position)
        }
    }

    private func recenter() {
        withViewportAnimation(.easeInOut(duration: 0.5)) {
            viewport = StreetnavExplorationMap.viewport(for: model.flowState, route: model.route, position: position)
        }
    }

    private func focus(on coordinates: [CLLocationCoordinate2D]) {
        if panelDetent == .large { panelDetent = StreetnavExplorePanel.preferredDetent(for: model.flowState) }
        withViewportAnimation(.easeInOut(duration: 0.6)) {
            viewport = StreetnavExplorationMap.focus(on: coordinates)
        }
    }

    private var navigationOverlay: some View {
        VStack(spacing: 0) {
            let instruction = model.route.instructions[safe: model.rideProgress.currentInstructionIndex] ?? model.route.instructions[0]
            StreetnavManeuverCard(instruction: instruction, gpsQuality: model.flowState == .weakGPS ? .weak : model.gpsQuality)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if model.flowState == .rerouting {
                StreetnavStatusPill(title: "Recalcul en cours", symbolName: "arrow.triangle.2.circlepath", tint: .orange, detail: "rue barree detectee")
                    .padding(.top, 10)
            }

            Spacer()

            HStack {
                StreetnavFloatingControl(symbolName: model.audioGuidanceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", label: "Guidage audio", isSelected: model.audioGuidanceEnabled) { model.audioGuidanceEnabled.toggle() }
                Spacer()
                StreetnavFloatingControl(symbolName: "location.fill", label: "Recentrer")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if model.showsCompletionToast {
                StreetnavCompletionToast(meters: 320)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            StreetnavRideProgressBar(progress: model.rideProgress)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            HStack(spacing: 12) {
                Button(model.flowState == .paused ? "Reprendre" : "Pause") {
                    model.flowState == .paused ? model.resumeRide() : model.pauseRide()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Rue terminee") { model.completeNewStreet() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Terminer") { showsEndConfirmation = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .background(.clear)
        }
    }

    private var arrivalOverlay: some View {
        VStack {
            Spacer()
            StreetnavBottomCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sortie terminee")
                        .font(.largeTitle.weight(.bold))
                    HStack {
                        StreetnavRouteMetric(title: "distance", value: String(format: "%.1f km", model.summary.distanceKilometers), symbolName: "point.topleft.down.curvedto.point.bottomright.up")
                        StreetnavRouteMetric(title: "duree", value: "\(model.summary.durationMinutes) min", symbolName: "clock")
                    }
                    HStack {
                        StreetnavRouteMetric(title: "nouvelles rues", value: String(format: "%.1f km", model.summary.newRoadKilometers), symbolName: "sparkle")
                        StreetnavRouteMetric(title: "en decouverte", value: "\(Int(model.summary.discoveryShare * 100))%", symbolName: "chart.pie")
                    }
                    Text(String(format: "+%.1f%% Wandrer estime. Le quartier passe de %d%% a %d%%.", model.summary.estimatedWandrerGain, Int(model.summary.areaCompletionBefore * 100), Int(model.summary.areaCompletionAfter * 100)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let heartRate = model.summary.heartRateAverage, let calories = model.summary.calories {
                        Text("Watch: \(heartRate) bpm moyen, \(calories) kcal estimees")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Strava se synchronise. Wandrer pourra etre mis a jour apres l'import des activites.")
                        .font(.subheadline)
                    HStack(spacing: 10) {
                        StreetnavPrimaryAction(title: "Enregistrer et synchroniser", symbolName: "arrow.triangle.2.circlepath") {}
                        Button("OK") { model.flowState = .home }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    HStack {
                        Button("Voir les rues") {}
                        Button("Partager") {}
                        Button("Signaler") {}
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(12)
        }
    }
}

struct StreetnavPlannerSheet: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @State private var showsAdvanced = false
    private let durations = [30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            Form {
                Section("Duree") {
                    Picker("Duree", selection: $model.selectedDuration) {
                        ForEach(durations, id: \.self) { duration in
                            Text("\(duration) min").tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Personnalise: \(model.selectedDuration) min", value: $model.selectedDuration, in: 20...120, step: 5)
                }

                Section("Profil") {
                    Picker("Priorite", selection: $model.plannerPriority) {
                        ForEach(PlannerPriority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                    Toggle("Boucle avec retour au depart", isOn: .constant(true))
                    Toggle("Destination precise", isOn: $model.destinationMode)
                }

                DisclosureGroup("Options avancees", isExpanded: $showsAdvanced) {
                    Toggle("Preferer les pistes protegees", isOn: $model.preferProtectedCycleways)
                    Toggle("Eviter les carrefours difficiles", isOn: $model.avoidDifficultIntersections)
                    Toggle("Eviter les paves", isOn: $model.avoidCobblestones)
                    Toggle("Limiter les rues repetees", isOn: $model.minimizeRepeatedRoads)
                }

                if model.isPlanningRoute {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Recherche des meilleures rues...")
                        }
                    }
                }

                if let routeErrorMessage = model.routeErrorMessage {
                    Section {
                        Text(routeErrorMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    StreetnavPrimaryAction(title: "Calculer l'itineraire", symbolName: "map", isLoading: model.isPlanningRoute) {
                        model.planRoute()
                    }
                }
            }
            .navigationTitle("Explorer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct StreetnavIntegrationSheet: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @ObservedObject private var healthSync = StreetnavHealthSync.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Sante") {
                    NavigationLink {
                        StreetnavHealthSyncView()
                    } label: {
                        row("Synchro avec le serveur", detail: healthText, symbol: "heart.text.square")
                    }
                }
                Section("Strava") {
                    row("Etat", detail: stravaText, symbol: stravaSymbol)
                    row("Derniere synchronisation", detail: model.integrations.lastStravaSyncText, symbol: "clock")
                    row("Sorties importees", detail: "\(model.integrations.importedRideCount)", symbol: "tray.full")
                    Button("Synchroniser maintenant") {}
                }
                Section("Wandrer Extra") {
                    row("Donnees importees", detail: model.integrations.wandrerConnected ? "connectees" : "a importer", symbol: "map")
                    row("Carte locale", detail: model.integrations.wandrerFreshnessText, symbol: "calendar")
                    row("Rues proches restantes", detail: "\(model.integrations.missingNearbyStreets)", symbol: "road.lanes")
                    Button("Importer ou mettre a jour") {}
                    Text("Prototype: donnees simulees, aucun compte reel n'est contacte.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Apple Watch") {
                    StreetnavDeviceStatusRow(title: model.watch.name, subtitle: model.watch.workoutReady ? "entrainement pret" : "non disponible", state: model.watch.state)
                    row("Frequence cardiaque", detail: model.watch.heartRateAvailable ? "disponible" : "indisponible", symbol: "heart")
                    row("Bouton Action", detail: model.watch.actionButtonReady ? "configure" : "concept futur", symbol: "button.programmable")
                }
                Section("VanMoof S6") {
                    StreetnavDeviceStatusRow(title: model.bike.name, subtitle: model.bike.connectionQuality, state: model.bike.state, trailing: model.bike.batteryPercent > 0 ? "\(model.bike.batteryPercent)%" : nil)
                    row("Verrou", detail: model.bike.isLocked ? "verrouille" : "deverrouille", symbol: model.bike.isLocked ? "lock" : "lock.open")
                    row("Automatisation deverrouillage", detail: "fonctionnalite future", symbol: "sparkles")
                }
            }
            .navigationTitle("Integrations")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private var healthText: String {
        if healthSync.isSyncing { return "synchro" }
        if healthSync.lastError != nil { return "erreur" }
        return healthSync.lastSync == nil ? "a configurer" : "a jour"
    }

    private var stravaText: String {
        switch model.integrations.stravaSync {
        case .connected: "connecte"
        case .disconnected: "deconnecte"
        case .tokenExpired: "session expiree"
        case .syncing: "synchro"
        case .updated: "a jour"
        case .unavailable: "indisponible"
        }
    }

    private var stravaSymbol: String {
        model.integrations.stravaSync == .connected ? "checkmark.circle" : "exclamationmark.circle"
    }
}

struct StreetnavRouteDetailsSheet: View {
    @ObservedObject var model: StreetnavPrototypeViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Surface") {
                    Text("\(Int(model.route.surface.cycleway * 100))% pistes cyclables")
                    Text("\(Int(model.route.surface.calmStreets * 100))% rues calmes")
                    Text("\(Int(model.route.surface.sharedRoads * 100))% routes partagees")
                }
                Section("Instructions") {
                    ForEach(model.route.instructions) { instruction in
                        Label(instruction.streetName, systemImage: instruction.symbolName)
                    }
                }
            }
            .navigationTitle("Detail")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
