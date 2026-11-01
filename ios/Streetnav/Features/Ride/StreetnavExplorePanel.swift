import CoreLocation
import SwiftUI

/// Sheets presented over the map screen.
enum StreetnavSheet: Identifiable {
    case planner
    case integrations
    case routeDetails
    #if DEBUG
    case gallery
    case tuning
    #endif

    var id: Self { self }
}

/// The card at the bottom of the map screen, laid out like the one in Maps: search and profile on top, then the
/// neighbourhood's progress, the route found or the last check before leaving. Shown as a sheet with detents over the
/// map, or inline when the screen is embedded in a development tool.
struct StreetnavExplorePanel: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @Binding var presentedSheet: StreetnavSheet?
    @Binding var detent: PresentationDetent
    var embedded = false
    var focus: ([CLLocationCoordinate2D]) -> Void = { _ in }

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL

    static let collapsed = PresentationDetent.height(92)
    static let summary = PresentationDetent.height(276)
    static let route = PresentationDetent.height(346)
    static let readiness = PresentationDetent.height(396)

    static func detents(for state: PrototypeFlowState) -> Set<PresentationDetent> {
        [collapsed, preferredDetent(for: state), .large]
    }

    /// Tall enough for the step's main button, no more, so that the map keeps most of the screen.
    static func preferredDetent(for state: PrototypeFlowState) -> PresentationDetent {
        switch state {
        case .routePreview: route
        case .readiness: readiness
        default: summary
        }
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView {
                    content
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sheet(item: $presentedSheet, onDismiss: sheetDismissed) { sheet in
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
            #if DEBUG
            case .gallery:
                StreetnavPrototypeGallery()
            case .tuning:
                StreetnavPrototypeTuningView()
            #endif
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            searchRow

            if isSearching {
                searchResults
            } else {
                switch model.flowState {
                case .routePreview:
                    routeContent
                case .readiness:
                    readinessContent
                default:
                    homeContent
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, embedded ? 16 : 20)
        .padding(.bottom, 24)
    }

    // MARK: Search

    private var isSearching: Bool { embedded == false && (searchFocused || query.isEmpty == false) }

    private var searchRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Rechercher une rue", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if query.isEmpty == false {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(.tertiarySystemFill), in: Capsule())

            if searchFocused {
                Button("Annuler") {
                    query = ""
                    searchFocused = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    presentedSheet = .integrations
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .streetnavGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Réglages")
            }
        }
        .animation(.snappy, value: searchFocused)
        .onChange(of: searchFocused) { _, focused in
            if focused { detent = .large }
        }
    }

    private var searchResults: some View {
        let matches = model.streets
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 10) {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Text(query.isEmpty ? "Rues autour de toi" : "Résultats")
                    .font(.headline)
                streetList(matches)
            }
        }
    }

    // MARK: Home

    @ViewBuilder
    private var homeContent: some View {
        notices

        if model.gpsQuality == .denied {
            message(
                symbol: "location.slash.fill",
                title: "Position désactivée",
                text: "Streetnav a besoin de ta position pour montrer les rues proches et préparer une boucle fiable.",
                action: "Ouvrir Réglages"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } else if model.integrations.wandrerConnected == false {
            message(
                symbol: "map",
                title: "Aucune rue importée",
                text: "Importe tes sorties pour distinguer les rues déjà parcourues de celles qu'il te reste à découvrir.",
                action: "Importer"
            ) {
                presentedSheet = .integrations
            }
        } else {
            areaSummary

            if model.area.missingStreetCount == 0 {
                message(
                    symbol: "checkmark.seal.fill",
                    title: "Quartier terminé",
                    text: "Tu as parcouru toutes les rues ici. Déplace la carte vers Bastille, Nation ou le Père-Lachaise pour continuer.",
                    action: nil
                ) {}
            } else {
                Button {
                    model.openPlanner()
                    presentedSheet = .planner
                } label: {
                    Label("Explorer", systemImage: "bicycle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }

            if embedded == false {
                moreContent
                    // Only once the panel is fully open, so that no half-cut row shows under the button.
                    .opacity(detent == .large ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: detent)
            }
        }
    }

    private var moreContent: some View {
        let untraveled = model.streets
            .filter { $0.status == .untraveled }
            .sorted { $0.lengthMeters > $1.lengthMeters }
        return VStack(alignment: .leading, spacing: 20) {
            if untraveled.isEmpty == false {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rues à découvrir près de toi")
                        .font(.headline)
                    streetList(untraveled)
                }
                .padding(.top, 8)
            }

            legend

            #if DEBUG
            developerSection
            #endif
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.integrations.isOffline {
            notice("Hors ligne, carte enregistrée sur l'iPhone", symbol: "wifi.slash")
        }
        if model.gpsQuality == .approximate || model.gpsQuality == .weak {
            notice(model.gpsQuality == .weak ? "Signal GPS faible" : "Position approximative", symbol: "location.slash")
        }
    }

    private var areaSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StreetnavProgressRing(progress: model.area.completion, lineWidth: 8)
                    .frame(width: 60, height: 60)
                    .overlay {
                        Text(model.area.completion.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.area.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(model.integrations.wandrerFreshnessText.prefix(1).uppercased() + model.integrations.wandrerFreshnessText.dropFirst())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 0) {
                stat(kilometers(model.area.remainingKilometers), unit: "km", label: "à découvrir")
                Divider().frame(height: 34)
                    .padding(.trailing, 16)
                stat("\(model.area.missingStreetCount)", unit: nil, label: model.area.missingStreetCount > 1 ? "rues restantes" : "rue restante")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem("Parcourues", status: .traveled)
            legendItem("À découvrir", status: .untraveled)
            legendItem("Itinéraire", status: .planned)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    #if DEBUG
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Développement")
                .font(.headline)
            card {
                Button { presentedSheet = .gallery } label: { row("Galerie des directions", symbol: "square.grid.2x2") }
                Divider().padding(.leading, 52)
                Button { presentedSheet = .tuning } label: { row("Laboratoire de réglages", symbol: "slider.horizontal.3") }
            }
        }
        .padding(.top, 8)
    }
    #endif

    // MARK: Route

    private var routeContent: some View {
        let route = model.route
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.title2.weight(.bold))
                    Text(route.isLoop ? "Boucle, retour vers \(route.arrivalText)" : "Arrivée vers \(route.arrivalText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                closeButton("Fermer l'itinéraire") { model.flowState = .home }
            }

            HStack(spacing: 0) {
                stat("\(route.durationMinutes)", unit: "min", label: "durée")
                stat(kilometers(route.distanceKilometers), unit: "km", label: "distance")
                stat(kilometers(route.newRoadKilometers), unit: "km", label: "rues nouvelles", tint: .red)
            }

            HStack(spacing: 8) {
                ForEach(route.alternatives) { alternative in
                    alternativeCard(alternative)
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button { presentedSheet = .planner } label: { Label("Modifier les réglages", systemImage: "slider.horizontal.3") }
                    Button { presentedSheet = .routeDetails } label: { Label("Détail du parcours", systemImage: "list.bullet") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Plus d'options")

                Button { model.prepareRide() } label: {
                    Text("Démarrer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }

            Text("\(route.elevationGainMeters) m de dénivelé, \(route.surface.cycleway.formatted(.percent.precision(.fractionLength(0)))) de pistes cyclables, \(route.confidence.label).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .opacity(detent == .large ? 1 : 0)
        }
        .sensoryFeedback(.selection, trigger: model.selectedAlternativeID)
    }

    /// One route option, three side by side so that the start button stays in view.
    private func alternativeCard(_ alternative: RouteAlternative) -> some View {
        let isSelected = model.selectedAlternativeID == alternative.id
        return Button {
            withAnimation(.snappy) { model.selectAlternative(alternative) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(alternative.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text("\(alternative.durationMinutes) min")
                        .foregroundStyle(.secondary)
                    Text("+\(kilometers(alternative.newRoadKilometers)) km")
                        .foregroundStyle(.red)
                }
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alternative.title), \(alternative.durationMinutes) minutes, \(kilometers(alternative.newRoadKilometers)) kilomètres de rues nouvelles")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Readiness

    private var readinessContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prêt à partir")
                        .font(.title2.weight(.bold))
                    Text("\(model.route.name), \(model.route.durationMinutes) min")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                closeButton("Revenir à l'itinéraire") { model.flowState = .routePreview }
            }

            card {
                checkRow(
                    symbol: "applewatch",
                    title: model.watch.name,
                    subtitle: model.watch.workoutReady ? "Entraînement vélo prêt" : "Tu peux partir sans montre",
                    state: model.watch.state
                )
                Divider().padding(.leading, 60)
                checkRow(
                    symbol: "bicycle",
                    title: model.bike.name,
                    subtitle: model.bike.state == .ready ? "Détecté, déverrouillage manuel" : "Facultatif pour cette sortie",
                    state: model.bike.state,
                    trailing: model.bike.batteryPercent > 0 ? model.bike.batteryPercent.formatted(.percent) : nil
                )
                Divider().padding(.leading, 60)
                checkRow(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Strava",
                    subtitle: "Synchronisation après la sortie",
                    state: model.integrations.stravaSync == .connected ? .ready : .actionRequired
                )
            }

            Button { model.startNavigation() } label: {
                Label("Lancer la navigation", systemImage: "location.north.line.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    // MARK: Building blocks

    private func streetList(_ streets: [ExplorationStreetSegment]) -> some View {
        card {
            ForEach(Array(streets.enumerated()), id: \.element.id) { index, street in
                if index > 0 { Divider().padding(.leading, 60) }
                Button {
                    searchFocused = false
                    focus(street.coordinates)
                } label: {
                    HStack(spacing: 12) {
                        StreetnavLegendLine(status: street.status)
                            .frame(width: 22, height: 6)
                            .frame(width: 32, height: 32)
                            .background(street.status.mapColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(street.name)
                                .foregroundStyle(.primary)
                            Text(street.status.label.prefix(1).uppercased() + street.status.label.dropFirst())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(kilometers(Double(street.lengthMeters) / 1000)) km")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(.tertiarySystemFill).opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stat(_ value: String, unit: String?, label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(tint == .primary ? Color.secondary : tint)
                }
            }
            .monospacedDigit()
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func message(symbol: String, title: String, text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            if let action {
                Button(action: perform) {
                    Text(action)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .labelStyle(StreetnavTintedIconLabelStyle(tint: .orange))
    }

    private func checkRow(symbol: String, title: String, subtitle: String, state: DeviceConnectionState, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(state.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: state.symbolName)
                .foregroundStyle(state.tint)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 32)
                .foregroundStyle(.tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private func closeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func legendItem(_ title: String, status: StreetExplorationStatus) -> some View {
        HStack(spacing: 6) {
            StreetnavLegendLine(status: status)
                .frame(width: 20, height: 6)
            Text(title)
        }
    }

    private func kilometers(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func sheetDismissed() {
        if model.flowState == .planner { model.flowState = .home }
    }
}

/// A short sample of the line a street status is drawn with on the map.
struct StreetnavLegendLine: View {
    let status: StreetExplorationStatus

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 3, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 3, y: size.height / 2))
            var stroke = status.mapStroke
            stroke.lineWidth = min(stroke.lineWidth, 4)
            context.stroke(path, with: .color(status.mapColor), style: stroke)
        }
        .accessibilityHidden(true)
    }
}

private struct StreetnavTintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private extension DeviceConnectionState {
    var tint: Color {
        switch self {
        case .ready: .green
        case .connecting: .orange
        case .unavailable: .gray
        case .actionRequired: .red
        }
    }
}

extension PrototypeFlowState {
    var isRouteStep: Bool { self == .routePreview || self == .readiness }
}
