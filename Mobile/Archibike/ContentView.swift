import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @State private var camera = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.8637, longitude: 2.3708),
            span: MKCoordinateSpan(latitudeDelta: 0.036, longitudeDelta: 0.036)
        )
    )
    @State private var step: StreetnavDemoStep = .home
    @State private var showPlanner = false
    @State private var showDevices = false
    @State private var selectedDuration = 45
    @State private var maximizeNewRoads = true
    @State private var protectedCycleways = true
    @State private var isLoadingRoute = false
    @State private var showCompletedToast = false
    @State private var audioEnabled = true
    @State private var showEndConfirmation = false

    var body: some View {
        ZStack {
            Map(position: $camera)
                .mapStyle(step.isNavigation ? .hybrid(elevation: .realistic) : .standard(elevation: .flat))
                .ignoresSafeArea()
                .overlay {
                    StreetnavDemoMapOverlay(mode: step)
                        .allowsHitTesting(false)
                }

            switch step {
            case .home:
                homeOverlay
            case .routePreview:
                routePreviewOverlay
            case .readiness:
                readinessOverlay
            case .navigation, .paused, .rerouting:
                navigationOverlay
            case .arrival:
                arrivalOverlay
            }
        }
        .sheet(isPresented: $showPlanner) { plannerSheet }
        .sheet(isPresented: $showDevices) { deviceSheet }
        .alert("Terminer la sortie ?", isPresented: $showEndConfirmation) {
            Button("Continuer", role: .cancel) {}
            Button("Terminer", role: .destructive) { step = .arrival }
        } message: {
            Text("Streetnav arretera la navigation et preparera le resume.")
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: step)
    }

    private var homeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StreetnavDemoSearchCapsule(text: "Canal Saint-Martin")
                Button { showDevices = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 30))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ouvrir les integrations")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(alignment: .top) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        StreetnavDemoPill("Wandrer", "il y a 2 j", "map.fill", .green)
                        StreetnavDemoPill("Strava", "il y a 6 min", "checkmark.circle.fill", .green)
                        StreetnavDemoPill("Watch", "prete", "applewatch", .green)
                        StreetnavDemoPill("VanMoof", "76%", "bicycle", .green)
                    }
                }
                Spacer()
                VStack(spacing: 10) {
                    StreetnavDemoRoundButton("location.fill", "Recentrer") {}
                    StreetnavDemoRoundButton("safari", "Boussole") {}
                    StreetnavDemoRoundButton("square.3.layers.3d", "Couches") {}
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            StreetnavDemoCard {
                HStack(spacing: 12) {
                    StreetnavDemoProgressRing(progress: 0.68)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Autour de toi")
                            .font(.title3.weight(.bold))
                        Text("12,4 km de rues encore a decouvrir")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    showPlanner = true
                } label: {
                    Label("Explorer", systemImage: "bicycle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(12)
        }
    }

    private var plannerSheet: some View {
        NavigationStack {
            Form {
                Section("Duree") {
                    Picker("Duree", selection: $selectedDuration) {
                        Text("30 min").tag(30)
                        Text("45 min").tag(45)
                        Text("60 min").tag(60)
                        Text("90 min").tag(90)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Personnalise: \(selectedDuration) min", value: $selectedDuration, in: 20...120, step: 5)
                }
                Section("Profil") {
                    Toggle("Boucle avec retour au depart", isOn: .constant(true))
                    Toggle("Maximiser les nouvelles rues", isOn: $maximizeNewRoads)
                    Toggle("Preferer les pistes protegees", isOn: $protectedCycleways)
                    Toggle("Eviter les paves", isOn: .constant(true))
                    Toggle("Limiter les rues repetees", isOn: .constant(false))
                }
                Section {
                    Button {
                        isLoadingRoute = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            isLoadingRoute = false
                            showPlanner = false
                            step = .routePreview
                        }
                    } label: {
                        HStack {
                            if isLoadingRoute { ProgressView() }
                            Text(isLoadingRoute ? "Recherche des meilleures rues..." : "Calculer l'itineraire")
                        }
                    }
                }
            }
            .navigationTitle("Explorer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var routePreviewOverlay: some View {
        VStack {
            Spacer()
            StreetnavDemoCard {
                Text("Boucle Canal - Nation")
                    .font(.title2.weight(.bold))
                Text("Retour au point de depart, arrivee 20:47")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    StreetnavDemoMetric("42 min", "duree", "clock")
                    StreetnavDemoMetric("8,4 km", "distance", "point.topleft.down.curvedto.point.bottomright.up")
                    StreetnavDemoMetric("3,1 km", "nouvelles rues", "sparkle")
                }
                HStack {
                    StreetnavDemoMetric("+1,9%", "Wandrer", "chart.line.uptrend.xyaxis")
                    StreetnavDemoMetric("54 m", "denivele", "mountain.2")
                    StreetnavDemoMetric("72%", "pistes", "bicycle")
                }
                HStack(spacing: 10) {
                    Button("Modifier") { showPlanner = true }
                        .buttonStyle(.bordered)
                    Button("Details") {}
                        .buttonStyle(.bordered)
                    Button { step = .readiness } label: {
                        Label("Demarrer", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(12)
        }
    }

    private var readinessOverlay: some View {
        VStack {
            Spacer()
            StreetnavDemoCard {
                Text("Pret a partir")
                    .font(.title2.weight(.bold))
                StreetnavDemoDeviceRow(title: "Apple Watch Ultra", detail: "Activite velo prete", icon: "checkmark.circle.fill", tint: .green)
                StreetnavDemoDeviceRow(title: "VanMoof S6", detail: "Detecte, deverrouillage manuel uniquement", icon: "checkmark.circle.fill", tint: .green)
                StreetnavDemoDeviceRow(title: "Strava", detail: "Synchronisation apres la sortie", icon: "checkmark.circle.fill", tint: .green)
                Button { step = .navigation } label: {
                    Label("Lancer la navigation", systemImage: "location.north.line.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
    }

    private var navigationOverlay: some View {
        VStack(spacing: 0) {
            StreetnavDemoManeuverCard(rerouting: step == .rerouting)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if step == .rerouting {
                StreetnavDemoPill("Recalcul", "rue barree detectee", "arrow.triangle.2.circlepath", .orange)
                    .padding(.top, 10)
            }

            Spacer()

            if showCompletedToast {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Nouvelle rue parcourue")
                            .font(.headline)
                        Text("+320 m decouverts")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            StreetnavDemoCard {
                ProgressView(value: 0.28)
                    .tint(.mint)
                HStack {
                    StreetnavDemoMetric("31 min", "restantes", "clock")
                    StreetnavDemoMetric("6,2 km", "a rouler", "point.topleft.down.curvedto.point.bottomright.up")
                    StreetnavDemoMetric("+320 m", "decouverts", "checkmark.seal")
                }
                HStack(spacing: 10) {
                    Button { audioEnabled.toggle() } label: {
                        Image(systemName: audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    Button(step == .paused ? "Reprendre" : "Pause") { step = step == .paused ? .navigation : .paused }
                        .buttonStyle(.borderedProminent)
                    Button("Rue terminee") {
                        showCompletedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCompletedToast = false }
                    }
                    .buttonStyle(.bordered)
                    Button("Terminer") { showEndConfirmation = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
                .controlSize(.large)
            }
            .padding(12)
        }
    }

    private var arrivalOverlay: some View {
        VStack {
            Spacer()
            StreetnavDemoCard {
                Text("Sortie terminee")
                    .font(.largeTitle.weight(.bold))
                HStack {
                    StreetnavDemoMetric("8,7 km", "distance", "point.topleft.down.curvedto.point.bottomright.up")
                    StreetnavDemoMetric("41 min", "duree", "clock")
                }
                HStack {
                    StreetnavDemoMetric("3,4 km", "nouvelles rues", "sparkle")
                    StreetnavDemoMetric("39%", "en decouverte", "chart.pie")
                }
                Text("+2,1% Wandrer estime. Strava se synchronise; Wandrer pourra etre mis a jour apres import.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Enregistrer et synchroniser") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("OK") { step = .home }
                    .buttonStyle(.bordered)
            }
            .padding(12)
        }
    }

    private var deviceSheet: some View {
        NavigationStack {
            List {
                Section("Strava") {
                    StreetnavDemoDeviceRow(title: "Connecte", detail: "Derniere synchro il y a 6 min", icon: "checkmark.circle.fill", tint: .green)
                    Text("184 sorties importees")
                }
                Section("Wandrer Extra") {
                    StreetnavDemoDeviceRow(title: "Donnees importees", detail: "Carte locale mise a jour il y a 2 jours", icon: "map.fill", tint: .green)
                    Text("38 rues proches restantes. Prototype: donnees simulees.")
                }
                Section("Apple Watch") {
                    StreetnavDemoDeviceRow(title: "Apple Watch Ultra", detail: "Workout pret, frequence cardiaque disponible", icon: "applewatch", tint: .green)
                }
                Section("VanMoof S6") {
                    StreetnavDemoDeviceRow(title: "VanMoof S6", detail: "Proche, batterie 76%, verrouille", icon: "bicycle", tint: .green)
                    Text("Deverrouillage automatique: fonctionnalite future.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Integrations")
        }
        .presentationDetents([.medium, .large])
    }
}

private enum StreetnavDemoStep {
    case home
    case routePreview
    case readiness
    case navigation
    case paused
    case rerouting
    case arrival

    var isNavigation: Bool {
        switch self {
        case .navigation, .paused, .rerouting: true
        default: false
        }
    }
}

private struct StreetnavDemoMapOverlay: View {
    let mode: StreetnavDemoStep

    var body: some View {
        Canvas { context, size in
            drawLine(in: &context, size: size, points: [CGPoint(x: 0.18, y: 0.34), CGPoint(x: 0.34, y: 0.40), CGPoint(x: 0.52, y: 0.36)], color: .blue, width: 5, opacity: 0.58)
            drawLine(in: &context, size: size, points: [CGPoint(x: 0.30, y: 0.58), CGPoint(x: 0.52, y: 0.53), CGPoint(x: 0.72, y: 0.62)], color: .red, width: 6, opacity: 0.78, dash: [8, 7])
            drawLine(in: &context, size: size, points: [CGPoint(x: 0.18, y: 0.46), CGPoint(x: 0.36, y: 0.42), CGPoint(x: 0.50, y: 0.49), CGPoint(x: 0.64, y: 0.61), CGPoint(x: 0.42, y: 0.75), CGPoint(x: 0.18, y: 0.46)], color: .mint, width: mode.isNavigation ? 11 : 8, opacity: 0.95)
            drawLine(in: &context, size: size, points: [CGPoint(x: 0.23, y: 0.68), CGPoint(x: 0.42, y: 0.66), CGPoint(x: 0.58, y: 0.72)], color: .green, width: 7, opacity: 0.86)
            drawLine(in: &context, size: size, points: [CGPoint(x: 0.61, y: 0.30), CGPoint(x: 0.75, y: 0.36), CGPoint(x: 0.84, y: 0.43)], color: .gray, width: 5, opacity: 0.62, dash: [4, 6])
        }
        .overlay {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: mode.isNavigation ? 36 : 30, weight: .semibold))
                .foregroundStyle(.white, .blue)
                .shadow(radius: 8)
        }
    }

    private func drawLine(in context: inout GraphicsContext, size: CGSize, points: [CGPoint], color: Color, width: CGFloat, opacity: Double, dash: [CGFloat] = []) {
        var path = Path()
        for (index, point) in points.enumerated() {
            let realPoint = CGPoint(x: point.x * size.width, y: point.y * size.height)
            index == 0 ? path.move(to: realPoint) : path.addLine(to: realPoint)
        }
        context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }
}

private struct StreetnavDemoSearchCapsule: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
            Text(text).font(.body.weight(.medium))
            Spacer()
            Image(systemName: "mic.fill").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
}

private struct StreetnavDemoCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
            content
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

private struct StreetnavDemoPill: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    init(_ title: String, _ detail: String, _ icon: String, _ tint: Color) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct StreetnavDemoRoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    init(_ icon: String, _ label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.13), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct StreetnavDemoMetric: View {
    let value: String
    let title: String
    let icon: String

    init(_ value: String, _ title: String, _ icon: String) {
        self.value = value
        self.title = title
        self.icon = icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StreetnavDemoProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 5)
            Circle().trim(from: 0, to: progress).stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))").font(.caption.weight(.bold))
        }
        .frame(width: 52, height: 52)
    }
}

private struct StreetnavDemoDeviceRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct StreetnavDemoManeuverCard: View {
    let rerouting: Bool
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: rerouting ? "arrow.triangle.2.circlepath" : "arrow.turn.up.right")
                .font(.system(size: 34, weight: .bold))
                .frame(width: 56, height: 56)
                .background(rerouting ? Color.orange : Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(rerouting ? "Recalcul" : "Dans 120 m")
                    .font(.title3.weight(.semibold))
                Text(rerouting ? "Reste sur l'axe" : "Tourne a droite")
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("Rue du Chemin-Vert")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().previewDisplayName("Streetnav Demo")
    }
}
