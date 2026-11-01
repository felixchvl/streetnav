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

/// The card at the bottom of the map screen, laid out like the one in Maps: search and settings on top, then the
/// neighbourhood's progress, the route found or the last check before leaving. Shown as a sheet with detents over the
/// map, or inline when the screen is embedded in a development tool. Follows the « Streetnav — Design » Figma file.
struct StreetnavExplorePanel: View {
    @ObservedObject var model: StreetnavPrototypeViewModel
    @Binding var presentedSheet: StreetnavSheet?
    @Binding var detent: PresentationDetent
    var embedded = false
    var focus: ([CLLocationCoordinate2D]) -> Void = { _ in }

    @State private var query = ""
    @State private var visibleHeight = CGFloat.greatestFiniteMagnitude
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL

    static let collapsed = PresentationDetent.height(92)
    static let summary = PresentationDetent.height(292)
    static let route = PresentationDetent.height(452)
    static let readiness = PresentationDetent.height(386)

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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                // Fully open, the panel turns into a grouped list, like a sheet in Maps: grey ground, white groups.
                .background(Color(.systemGroupedBackground).opacity(detent == .large ? 1 : 0).ignoresSafeArea())
                .animation(.easeInOut(duration: 0.2), value: detent)
            }
        }
        .sheet(item: $presentedSheet, onDismiss: sheetDismissed) { sheet in
            switch sheet {
            case .planner:
                StreetnavPlannerSheet(model: model)
                    .presentationDetents([.large])
            case .integrations:
                StreetnavIntegrationSheet(model: model)
                    .presentationDetents([.large])
            case .routeDetails:
                StreetnavRouteDetailsSheet(model: model)
                    .presentationDetents([.medium, .large])
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
        VStack(alignment: .leading, spacing: 16) {
            if model.flowState.isRouteStep == false || isSearching {
                searchRow
            }

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
                        .opacity(homeOpacity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, embedded ? 16 : 20)
        .padding(.bottom, 24)
    }

    /// Lowered to the search row, the neighbourhood's card fades out with the panel instead of being cut by it.
    private var homeOpacity: Double {
        embedded ? 1 : min(1, max(0, (visibleHeight - 110) / 90))
    }

    // MARK: Search

    private var isSearching: Bool { embedded == false && (searchFocused || query.isEmpty == false) }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
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
                } else {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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
        return Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                section("Rues") {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, street in
                        if index > 0 { separator }
                        streetRow(street, detail: "\(street.status.label.capitalizedFirst) · \(kilometers(street.lengthMeters)) km")
                    }
                }
            }
        }
    }

    // MARK: Home

    @ViewBuilder
    private var homeContent: some View {
        notices

        if model.gpsQuality == .denied {
            message(
                symbol: "location.slash",
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
                text: "Tes sorties n'ont pas encore été comparées aux rues du quartier.",
                action: "Réglages"
            ) {
                presentedSheet = .integrations
            }
        } else {
            areaSummary

            if model.area.missingStreetCount == 0 {
                message(
                    symbol: "checkmark.seal",
                    title: "Quartier terminé",
                    text: "Tu as parcouru toutes les rues ici. Déplace la carte vers un autre quartier pour continuer.",
                    action: nil
                ) {}
            } else {
                primaryButton("Explorer", symbol: "bicycle") {
                    model.openPlanner()
                    presentedSheet = .planner
                }
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
        return VStack(alignment: .leading, spacing: 16) {
            if untraveled.isEmpty == false {
                section("À découvrir près de toi") {
                    ForEach(Array(untraveled.enumerated()), id: \.element.id) { index, street in
                        if index > 0 { separator }
                        streetRow(street, detail: "\(kilometers(street.lengthMeters)) km jamais parcourus")
                    }
                }
            }

            if model.recentRides.isEmpty == false {
                section("Dernières sorties") {
                    ForEach(Array(model.recentRides.enumerated()), id: \.element.id) { index, ride in
                        if index > 0 { separator }
                        row(symbol: "figure.outdoor.cycle", title: ride.name, detail: ride.detail, chevron: true)
                    }
                }
            }

            #if DEBUG
            section("Développement") {
                Button { presentedSheet = .gallery } label: { row(symbol: "square.grid.2x2", title: "Galerie des directions", chevron: true) }
                    .buttonStyle(.plain)
                separator
                Button { presentedSheet = .tuning } label: { row(symbol: "slider.horizontal.3", title: "Laboratoire de réglages", chevron: true) }
                    .buttonStyle(.plain)
            }
            #endif
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.integrations.isOffline {
            Label("Hors ligne, carte enregistrée sur l'iPhone", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if model.gpsQuality == .approximate || model.gpsQuality == .weak {
            Label(model.gpsQuality == .weak ? "Signal GPS faible" : "Position approximative", systemImage: "location.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var areaSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                StreetnavProgressRing(progress: model.area.completion, lineWidth: 7)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.area.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(model.area.completion.formatted(.percent.precision(.fractionLength(0)))) des rues parcourues")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .top, spacing: 12) {
                stat("À découvrir", value: kilometers(model.area.remainingKilometers), unit: "km")
                stat("Rues restantes", value: "\(model.area.missingStreetCount)", unit: nil)
                stat("Sorties", value: model.integrations.importedRideCount.formatted(), unit: nil)
            }
        }
    }

    // MARK: Route

    private var routeContent: some View {
        let route = model.route
        return VStack(alignment: .leading, spacing: 16) {
            header(route.name, subtitle: "\(route.isLoop ? "Boucle" : "Aller simple") · retour vers \(route.arrivalText)", close: "Fermer l'itinéraire") {
                model.flowState = .home
            }

            HStack(alignment: .top, spacing: 12) {
                stat("Durée", value: "\(route.durationMinutes)", unit: "min")
                stat("Distance", value: kilometers(route.distanceKilometers), unit: "km")
                stat("Nouvelles", value: kilometers(route.newRoadKilometers), unit: "km")
            }

            group {
                ForEach(Array(route.alternatives.enumerated()), id: \.element.id) { index, alternative in
                    if index > 0 { separator(leading: 16) }
                    alternativeRow(alternative)
                }
            }

            HStack(spacing: 12) {
                Button { presentedSheet = .routeDetails } label: {
                    Label("Détails", systemImage: "list.bullet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)

                Button { model.prepareRide() } label: {
                    Text("Démarrer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .sensoryFeedback(.selection, trigger: model.selectedAlternativeID)
    }

    private func alternativeRow(_ alternative: RouteAlternative) -> some View {
        let isSelected = model.selectedAlternativeID == alternative.id
        return Button {
            withAnimation(.snappy) { model.selectAlternative(alternative) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(alternative.title)
                        .foregroundStyle(.primary)
                    Text("\(alternative.durationMinutes) min · \(alternative.subtitle)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Readiness

    private var readinessContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Prêt à partir", subtitle: "\(model.route.name) · \(model.route.durationMinutes) min", close: "Revenir à l'itinéraire") {
                model.flowState = .routePreview
            }

            group {
                row(symbol: "applewatch", title: model.watch.name,
                    detail: model.watch.workoutReady ? "Entraînement vélo prêt" : "Tu peux partir sans montre")
                separator
                row(symbol: "bicycle", title: model.bike.name,
                    detail: model.bike.state == .ready ? "Détecté · déverrouillage manuel" : "Facultatif pour cette sortie",
                    value: model.bike.batteryPercent > 0 ? model.bike.batteryPercent.formatted(.percent) : nil)
                separator
                row(symbol: "server.rack", title: "Serveur Streetnav", detail: "Envoi automatique après la sortie")
            }

            primaryButton("Lancer la navigation", symbol: "location.north.line.fill") { model.startNavigation() }
        }
    }

    // MARK: Building blocks

    private func header(_ title: String, subtitle: String, close: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .streetnavGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(close)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)
            group(content: content)
        }
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var separator: some View { separator(leading: 56) }

    private func separator(leading: CGFloat) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1 / 3)
            .padding(.leading, leading)
    }

    private func streetRow(_ street: ExplorationStreetSegment, detail: String) -> some View {
        Button {
            searchFocused = false
            focus(street.coordinates)
        } label: {
            row(symbol: "road.lanes", title: street.name, detail: detail, chevron: true)
        }
        .buttonStyle(.plain)
    }

    /// A row like the ones in Settings: grey symbol, title and optional detail, optional value and chevron.
    private func row(symbol: String, title: String, detail: String? = nil, value: String? = nil, chevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: detail == nil ? 52 : 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, value: String, unit: String?) -> some View {
        StreetnavStat(label: label, value: value, unit: unit)
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
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
                    .foregroundStyle(.secondary)
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

    private func kilometers(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func kilometers(_ meters: Int) -> String {
        kilometers(Double(meters) / 1000)
    }

    private func sheetDismissed() {
        if model.flowState == .planner { model.flowState = .home }
    }
}

extension PrototypeFlowState {
    var isRouteStep: Bool { self == .routePreview || self == .readiness }
}

extension String {
    /// « à découvrir » → « À découvrir ».
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
