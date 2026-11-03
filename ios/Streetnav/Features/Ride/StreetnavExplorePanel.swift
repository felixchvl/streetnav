import CoreLocation
import MapKit
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
    @ObservedObject var places: StreetnavPlaceSearch
    @ObservedObject private var guidance = StreetnavGuidance.shared
    @ObservedObject private var history = StreetnavRideHistory.shared
    @ObservedObject private var healthSync = StreetnavHealthSync.shared
    @Binding var presentedSheet: StreetnavSheet?
    @Binding var detent: PresentationDetent
    var embedded = false
    var focus: ([CLLocationCoordinate2D]) -> Void = { _ in }

    @State private var query = ""
    /// The suggestion just chosen, shown as its card at once while its location comes, as Maps does.
    @State private var choosing: StreetnavSuggestion?
    @State private var visibleHeight = CGFloat.greatestFiniteMagnitude
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL

    /// Just the search bar, 65 points tall on screen like the one in Maps.
    static let collapsed = PresentationDetent.height(76)
    static let summary = PresentationDetent.height(292)
    /// A place's card with its ways there.
    static let place = PresentationDetent.height(440)
    static let route = PresentationDetent.height(452)
    static let readiness = PresentationDetent.height(386)

    static func detents(for state: PrototypeFlowState, place: Bool = false) -> Set<PresentationDetent> {
        // Three positions, as in Maps: the search bar, half open (taller for a place) and fully open.
        [collapsed, place && state == .home ? Self.place : middleDetent(for: state), .large]
    }

    /// Tall enough for the step's main button, no more, so that the map keeps most of the screen.
    static func middleDetent(for state: PrototypeFlowState) -> PresentationDetent {
        switch state {
        case .routePreview: route
        case .readiness: readiness
        default: summary
        }
    }

    /// Where the panel opens: half open, as in Maps.
    static func preferredDetent(for state: PrototypeFlowState) -> PresentationDetent {
        middleDetent(for: state)
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                // A department or a ring of the statistics opens on a page of its own, as in Maps.
                NavigationStack {
                    ScrollView {
                        content
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                    // Fully open, the panel turns opaque, like the sheet in Maps.
                    .background(Color(.systemGroupedBackground).opacity(detent == .large ? 1 : 0).ignoresSafeArea())
                    .animation(.easeInOut(duration: 0.2), value: detent)
                    .containerBackground(.clear, for: .navigation)
                    .navigationTitle("Tes sorties")
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: StreetnavZoneGroup.self) { group in
                        StreetnavZonePage(group: group, all: history.stats?.zones ?? [], shapes: history.zoneShapes)
                            .onAppear { detent = .large }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { guidance.isActive }, set: { if $0 == false { guidance.stop() } })) {
            StreetnavGuidanceView()
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
            // A place's card replaces the search bar, as in Maps.
            if (model.flowState.isRouteStep == false && places.place == nil && choosing == nil) || isSearching {
                searchRow
            }

            if isSearching {
                searchResults
            } else if let place = places.place, model.flowState.isRouteStep == false {
                placeContent(place)
            } else if let choosing, model.flowState.isRouteStep == false {
                VStack(spacing: 6) {
                    Text(choosing.title)
                        .font(.title2.weight(.bold))
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
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
        // Maps' margins. Collapsed, iOS draws the panel about 14 % smaller: these give Maps' 16 points around the field on
        // screen and centre it in the bar. Fully open, 17 points.
        .padding(.horizontal, detent == .large ? 17 : 18)
        .padding(.top, embedded ? 16 : (detent == .large ? 16 : 16))
        .padding(.bottom, 24)
    }

    /// Lowered to the search row, the neighbourhood's card fades out with the panel instead of being cut by it.
    private var homeOpacity: Double {
        embedded ? 1 : min(1, max(0, (visibleHeight - 110) / 90))
    }

    // MARK: Search

    private var isSearching: Bool { embedded == false && (searchFocused || query.isEmpty == false) }
    private var searchExpanded: Bool { isSearching && detent == .large }
    private var collapsedBar: Bool { detent == StreetnavExplorePanel.collapsed && embedded == false }

    private var searchRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                // Light symbols and placeholder, as in Maps.
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.primary)
                TextField("Streetnav", text: $query, prompt: Text("Streetnav").foregroundStyle(.secondary))
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, text in places.update(query: text) }
                    .onSubmit {
                        if let first = places.suggestions.first { choose(first) }
                    }
                // No microphone: the keyboard's dictation is there for that.
                if query.isEmpty == false {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .font(.system(size: collapsedBar ? 20 : 17))
            .padding(.horizontal, 12)
            // The whole bar opens the search, as in Maps.
            .contentShape(Capsule())
            .onTapGesture { searchFocused = true }
            // 44 points, which iOS shows as Maps' 38 in the collapsed bar.
            .frame(height: 44)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

            Button {
                if searchExpanded {
                    query = ""
                    searchFocused = false
                    detent = StreetnavExplorePanel.preferredDetent(for: model.flowState)
                } else {
                    presentedSheet = .integrations
                }
            } label: {
                // A plain round fill in the bar, like the account button in Maps; glass once the panel is open.
                Image(systemName: searchExpanded ? "xmark" : "gearshape")
                    .font(.system(size: searchExpanded ? 19 : 21, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.tertiarySystemFill)).opacity(searchExpanded ? 0 : 1))
                    .streetnavGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchExpanded ? "Fermer la recherche" : "Réglages")
        }
        .animation(.snappy, value: searchFocused)
        .onChange(of: searchFocused) { _, focused in
            if focused { detent = .large }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let problem = places.problem {
            ContentUnavailableView("Recherche indisponible", systemImage: "exclamationmark.magnifyingglass",
                                   description: Text(problem))
        } else if query.isEmpty == false && places.suggestions.isEmpty && places.isLooking == false {
            ContentUnavailableView("Aucun résultat", systemImage: "magnifyingglass",
                                   description: Text("Rien ne correspond à « \(query) » autour de toi."))
        } else if places.suggestions.isEmpty == false {
            group {
                ForEach(Array(places.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    if index > 0 { separator(leading: 64) }
                    Button {
                        choose(suggestion)
                    } label: {
                        resultRow(suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 3)
            if places.usesGoogle {
                // Google asks for its name next to its suggestions.
                Text("Suggestions de Google Maps")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    /// A line of results in Maps: the place's icon in a 32-point circle, its name in bold and its address.
    private func resultRow(_ suggestion: StreetnavSuggestion) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "mappin")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.red))
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if suggestion.subtitle.isEmpty == false {
                    Text(suggestion.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }

    private func choose(_ suggestion: StreetnavSuggestion) {
        query = ""
        searchFocused = false
        detent = StreetnavExplorePanel.summary
        choosing = suggestion
        Task {
            await places.choose(suggestion)
            choosing = nil
        }
    }

    // MARK: Place

    /// A place's card: only a destination to ride to. Its name, then the ways there, the most direct one and those going
    /// out of their way along streets still to ride, each with its new kilometres; the one chosen is drawn on the map.
    private func placeContent(_ place: StreetnavPlace) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                // As wide as the close button, so that the name stays centred.
                Color.clear.frame(width: 44, height: 44)
                VStack(spacing: 2) {
                    Text(place.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text(placeSubtitle(place))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                Button {
                    places.clear()
                    detent = StreetnavExplorePanel.preferredDetent(for: model.flowState)
                } label: { glassIcon("xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fermer le lieu")
            }

            if places.routes.isEmpty {
                if places.routeFailed {
                    Text("Itinéraire vélo indisponible")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Calcul des itinéraires…")
                        .font(.subheadline)
                        .frame(height: 60)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(places.routes) { route in
                        routeChoice(route, fastest: places.routes[0])
                    }
                }
                primaryButton(guidance.isStarting ? "Calcul…" : "Partir", symbol: "bicycle") {
                    guard let route = places.route else { return }
                    Task { await guidance.start(to: place, from: places.hereLocation, via: route.via) }
                }
                .disabled(guidance.isStarting)
            }
            if let failure = guidance.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, -4)
    }

    /// A way there, as Maps lists its routes: the time large, the distance and arrival under it, and what it brings.
    private func routeChoice(_ route: StreetnavBikeRoute, fastest: StreetnavBikeRoute) -> some View {
        let selected = places.route?.kind == route.kind
        let minutes = Duration.seconds(route.durationSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let arrival = Date.now.addingTimeInterval(route.durationSeconds).formatted(date: .omitted, time: .shortened)
        let extra = route.durationSeconds - fastest.durationSeconds
        return Button {
            places.selected = route.kind
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(minutes)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text(route.kind.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text([kilometers(route.distanceMeters / 1000) + " km", route.kind == .direct ? nil : "+\(Int((extra / 60).rounded())) min",
                          "arrivée " + arrival].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let new = route.newMeters {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(kilometers(new / 1000)) km")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(new > 0 ? Color.red : Color.secondary)
                        Text("à découvrir")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(selected ? 0 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func glassIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .streetnavGlass(in: Circle(), interactive: true)
    }

    private func placeSubtitle(_ place: StreetnavPlace) -> String {
        guard let meters = places.distanceFromHere else { return place.address }
        let distance = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return place.address.isEmpty ? "À \(distance)" : "\(place.address) · \(distance)"
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
        } else if let stats = history.stats {
            ridesSummary(stats)
            primaryButton("Explorer", symbol: "bicycle") {
                model.openPlanner()
                presentedSheet = .planner
            }
            // Goes on under the button, cut by the panel half open, as the Recents are in Maps.
            ridesDetails(stats)
        } else {
            message(
                symbol: "server.rack",
                title: "Aucune sortie",
                text: "Relie Streetnav à ton serveur dans Réglages pour voir tes sorties sur la carte.",
                action: "Réglages"
            ) {
                presentedSheet = .integrations
            }
        }
    }

    // MARK: Rides

    /// This year, this month and the last 30 days, from the server.
    private func ridesSummary(_ stats: StreetnavRideHistory.Stats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "figure.outdoor.cycle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tes sorties")
                        .font(.title2.weight(.bold))
                    Text(lastRideText(stats))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    healthStatus
                }
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .top, spacing: 12) {
                stat("Cette année", value: distance(stats.thisYear.km), unit: "km")
                stat("Ce mois-ci", value: distance(stats.thisMonth.km), unit: "km")
                if let streets = stats.streets, streets.totalKm > 0 {
                    stat("Rues", value: (streets.share * 100).formatted(.number.precision(.fractionLength(0))), unit: "%")
                } else {
                    stat("30 jours", value: "\(stats.last30Days.rides)", unit: stats.last30Days.rides > 1 ? "sorties" : "sortie")
                }
            }
        }
    }

    /// Less is more: the totals, then where the streets were discovered, on maps darker where more were ridden, each
    /// department and ring opening on a page of its own.
    private func ridesDetails(_ stats: StreetnavRideHistory.Stats) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Depuis le début") {
                row(symbol: "figure.outdoor.cycle", title: "Sorties", value: stats.total.rides.formatted())
                separator
                row(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Distance",
                    value: "\(distance(stats.total.km)) km")
                separator
                row(symbol: "clock", title: "Temps en selle", value: "\(distance(stats.total.hours)) h")
                separator
                row(symbol: "mountain.2", title: "Dénivelé", value: "\(stats.total.climbM.formatted()) m")
            }

            if let streets = stats.streets, streets.totalKm > 0 {
                section("Rues découvertes") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let zones = stats.zones, history.zoneShapes.isEmpty == false {
                            StreetnavZoneMap(shapes: history.zoneShapes, zones: zones)
                                .frame(height: 280)
                            StreetnavZoneLegend()
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text("\((streets.share * 100).formatted(.number.precision(.fractionLength(1)).locale(Self.french))) %")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("des rues · \(distance(streets.riddenKm)) km sur \(distance(streets.totalKm))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }

            if let zones = stats.zones, zones.isEmpty == false {
                zoneGroups("Par département", StreetnavZoneGroup.departments(zones))
                zoneGroups("Par couronne", StreetnavZoneGroup.rings(zones))
            }

            if history.isOffline {
                Label("Serveur injoignable : chiffres de la dernière connexion.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.top, 8)
    }

    /// Each department or ring: its small map, its share and kilometres; a tap opens its page.
    private func zoneGroups(_ title: String, _ groups: [StreetnavZoneGroup]) -> some View {
        section(title) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { separator(leading: 80) }
                NavigationLink(value: group) {
                    HStack(spacing: 12) {
                        if history.zoneShapes.isEmpty == false {
                            StreetnavZoneMap(shapes: history.zoneShapes, zones: group.zones, borders: false)
                                .frame(width: 52, height: 52)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                                .font(.headline)
                            Text(group.totalKm > 0 ? "\(group.detail) · \(distance(group.riddenKm)) km sur \(distance(group.totalKm))"
                                 : "\(group.detail) · rues pas encore chargées")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(group.totalKm > 0 ? "\((group.share * 100).formatted(.number.precision(.fractionLength(0)).locale(Self.french))) %" : "–")
                            .font(.headline)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Whether every Apple Health workout has reached the server: when the app last checked, or why it could not.
    private var healthStatus: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let (text, symbol, color) = healthState(now: context.date)
            Label {
                Text(text)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(color)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func healthState(now: Date) -> (String, String, Color) {
        if healthSync.isSyncing { return ("Santé : synchronisation…", "arrow.triangle.2.circlepath", .secondary) }
        guard let last = healthSync.lastSync else { return ("Santé : à configurer", "heart.slash", .orange) }
        if healthSync.waitsForUnlock { return ("Santé : en attente du déverrouillage", "lock.fill", .orange) }
        if healthSync.lastError != nil { return ("Santé : pas synchronisée", "exclamationmark.triangle.fill", .orange) }
        let ago = last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(Self.french))
        // Checked at every opening and in the background: half a day without a check means something is wrong.
        if now.timeIntervalSince(last) > 12 * 3600 { return ("Santé vérifiée \(ago)", "clock.badge.exclamationmark", .orange) }
        return ("Santé à jour · vérifiée \(ago)", "checkmark.circle.fill", .green)
    }

    private func lastRideText(_ stats: StreetnavRideHistory.Stats) -> String {
        guard let date = stats.lastRideDate else { return "\(stats.total.rides) sorties" }
        // With the hour, to tell at a glance that it is the very last one.
        return "Dernière le \(date.formatted(.dateTime.day().month(.wide).locale(Self.french))) à \(date.formatted(.dateTime.hour().minute().locale(Self.french)))"
    }

    private static let french = Locale(identifier: "fr_FR")

    /// Kilometres as Maps shows them: a decimal under 100, none above.
    private func distance(_ km: Double) -> String {
        km.formatted(.number.precision(.fractionLength(km < 100 ? 1 : 0)).locale(Self.french))
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
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var separator: some View { separator(leading: 56) }

    private func separator(leading: CGFloat) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1 / 3)
            .padding(.leading, leading)
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
