import SwiftUI

@MainActor
struct StreetnavRecommendedView: View {
    @StateObject private var model: StreetnavPrototypeViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSheet: SheetKind?
    @State private var showsEndConfirmation = false

    init() {
        _model = StateObject(wrappedValue: StreetnavPrototypeViewModel())
    }

    init(model: StreetnavPrototypeViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            StreetnavMapSurface(
                segments: model.streets,
                route: model.flowState == .home || model.flowState == .planner ? nil : model.route,
                mode: model.flowState,
                tuning: model.tuning,
                muted: model.flowState.isNavigationLike
            )

            switch model.flowState {
            case .home, .planner, .routePreview, .readiness:
                homeOverlay
            case .navigating, .approachingNewStreet, .completedNewStreet, .rerouting, .weakGPS, .paused:
                navigationOverlay
            case .arrived:
                arrivalOverlay
            }
        }
        .task { await model.load() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .planner:
                StreetnavPlannerSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .integrations:
                StreetnavIntegrationSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .routeDetails:
                StreetnavRouteDetailsSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert("Terminer la sortie ?", isPresented: $showsEndConfirmation) {
            Button("Continuer", role: .cancel) {}
            Button("Terminer", role: .destructive) { model.finishRide() }
        } message: {
            Text("La navigation s'arretera et Streetnav preparera le resume de la sortie.")
        }
        .animation(StreetnavMotion.spring(model.tuning, reduceMotion: reduceMotion || model.tuning.simulateReducedMotion), value: model.flowState)
    }

    private var homeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StreetnavSearchCapsule(text: model.gpsQuality == .denied ? "Activer la position" : "Canal Saint-Martin")
                Button { presentedSheet = .integrations } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 30))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ouvrir les integrations et le compte")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    statusStrip
                    if model.integrations.isOffline {
                        StreetnavStatusPill(title: "Hors ligne", symbolName: "wifi.slash", tint: .orange, detail: "carte locale")
                    }
                    if model.gpsQuality != .precise {
                        StreetnavStatusPill(title: model.gpsQuality.label, symbolName: "location.slash", tint: .orange)
                    }
                }
                Spacer()
                VStack(spacing: 10) {
                    StreetnavFloatingControl(symbolName: "location.fill", label: "Recentrer la carte")
                    StreetnavFloatingControl(symbolName: "safari", label: "Afficher la boussole", isSelected: model.flowState.isNavigationLike)
                    StreetnavFloatingControl(symbolName: "square.3.layers.3d", label: "Choisir les couches")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if model.flowState == .routePreview || model.flowState == .readiness {
                routePreviewCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                homeBottomCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StreetnavStatusPill(title: "Wandrer", symbolName: model.integrations.wandrerConnected ? "map.fill" : "map", tint: model.integrations.wandrerConnected ? .green : .orange, detail: model.integrations.wandrerFreshnessText)
                StreetnavStatusPill(title: "Strava", symbolName: stravaSymbol, tint: stravaTint, detail: model.integrations.lastStravaSyncText)
                StreetnavStatusPill(title: "Watch", symbolName: model.watch.state.symbolName, tint: model.watch.state == .ready ? .green : .secondary)
                StreetnavStatusPill(title: "VanMoof", symbolName: model.bike.state.symbolName, tint: model.bike.state == .ready ? .green : .orange, detail: "\(model.bike.batteryPercent)%")
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 310)
    }

    private var homeBottomCard: some View {
        StreetnavBottomCard {
            HStack(alignment: .center, spacing: 12) {
                StreetnavExplorationBadge(area: model.area)
                Spacer(minLength: 8)
                StreetnavMapLegend()
                    .fixedSize()
            }

            if model.gpsQuality == .denied {
                Text("Streetnav a besoin de ta position pour montrer les rues proches et preparer une boucle fiable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                StreetnavPrimaryAction(title: "Ouvrir les reglages", symbolName: "gearshape") {}
            } else if model.integrations.wandrerConnected == false {
                Text("Importe tes donnees Wandrer pour distinguer les rues deja parcourues des rues restantes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                StreetnavPrimaryAction(title: "Importer Wandrer", symbolName: "tray.and.arrow.down") { presentedSheet = .integrations }
            } else if model.area.missingStreetCount == 0 {
                Text("Ce quartier est complet. Deplace la carte vers Bastille, Nation ou Pere-Lachaise pour continuer l'exploration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                StreetnavPrimaryAction(title: "Chercher autour", symbolName: "magnifyingglass") {}
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Autour de toi")
                        .font(.title3.weight(.bold))
                    Text(String(format: "%.1f km de rues encore a decouvrir", model.area.remainingKilometers))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                StreetnavPrimaryAction(title: "Explorer", symbolName: "bicycle") {
                    model.openPlanner()
                    presentedSheet = .planner
                }
            }
        }
    }

    private var routePreviewCard: some View {
        StreetnavBottomCard {
            if model.flowState == .readiness {
                readinessContent
            } else {
                routePreviewContent
            }
        }
    }

    private var routePreviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.route.name)
                        .font(.title2.weight(.bold))
                    Text("Retour au point de depart, arrivee \(model.route.arrivalText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.route.confidence.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.16), in: Capsule())
            }

            HStack {
                StreetnavRouteMetric(title: "duree", value: "\(model.route.durationMinutes) min", symbolName: "clock")
                StreetnavRouteMetric(title: "distance", value: String(format: "%.1f km", model.route.distanceKilometers), symbolName: "point.topleft.down.curvedto.point.bottomright.up")
                StreetnavRouteMetric(title: "nouvelles rues", value: String(format: "%.1f km", model.route.newRoadKilometers), symbolName: "sparkle")
            }
            HStack {
                StreetnavRouteMetric(title: "gain Wandrer", value: String(format: "+%.1f%%", model.route.estimatedProgressGain), symbolName: "chart.line.uptrend.xyaxis")
                StreetnavRouteMetric(title: "denivele", value: "+\(model.route.elevationGainMeters) m", symbolName: "mountain.2")
                StreetnavRouteMetric(title: "surface", value: "72% pistes", symbolName: "bicycle")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.route.alternatives) { alternative in
                        StreetnavRouteAlternativeCard(alternative: alternative, isSelected: model.selectedAlternativeID == alternative.id) {
                            withAnimation { model.selectAlternative(alternative) }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Modifier") { presentedSheet = .planner }
                    .buttonStyle(.bordered)
                Menu {
                    Button("Enregistrer") {}
                    Button("Partager plus tard") {}
                    Button("Inspecter le detail") { presentedSheet = .routeDetails }
                } label: {
                    Label("Plus", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
                StreetnavPrimaryAction(title: "Demarrer", symbolName: "play.fill") { model.prepareRide() }
            }
        }
    }

    private var readinessContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pret a partir")
                .font(.title2.weight(.bold))
            StreetnavDeviceStatusRow(title: model.watch.name, subtitle: model.watch.workoutReady ? "Activite velo prete a demarrer" : "Tu peux partir sans Watch", state: model.watch.state)
            StreetnavDeviceStatusRow(title: model.bike.name, subtitle: model.bike.state == .ready ? "detecte, deverrouillage manuel uniquement" : "optionnel pour cette sortie", state: model.bike.state, trailing: model.bike.batteryPercent > 0 ? "\(model.bike.batteryPercent)%" : nil)
            StreetnavDeviceStatusRow(title: "Strava", subtitle: "synchronisation apres la sortie", state: model.integrations.stravaSync == .connected ? .ready : .actionRequired)
            StreetnavPrimaryAction(title: "Lancer la navigation", symbolName: "location.north.line.fill") { model.startNavigation() }
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

    private var stravaSymbol: String {
        switch model.integrations.stravaSync {
        case .connected, .updated: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .disconnected: "link.badge.plus"
        case .tokenExpired: "exclamationmark.circle.fill"
        case .unavailable: "minus.circle.fill"
        }
    }

    private var stravaTint: Color {
        switch model.integrations.stravaSync {
        case .connected, .updated: .green
        case .syncing: .orange
        case .disconnected, .tokenExpired: .red
        case .unavailable: .secondary
        }
    }
}

private enum SheetKind: Identifiable {
    case planner
    case integrations
    case routeDetails
    var id: Int { hashValue }
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

    var body: some View {
        NavigationStack {
            List {
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
