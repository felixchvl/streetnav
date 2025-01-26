import SwiftUI

enum StreetnavDirection: String, CaseIterable, Identifiable {
    case quietPrecision = "Quiet Precision"
    case streetPulse = "Street Pulse"
    case completionHunt = "Completion Hunt"
    case rideFocus = "Ride Focus"
    case nightExplorer = "Night Explorer"
    case recommended = "Streetnav Recommended"

    var id: String { rawValue }
}

struct StreetnavPrototypeGallery: View {
    @State private var direction: StreetnavDirection = .recommended

    var body: some View {
        VStack(spacing: 0) {
            Picker("Direction", selection: $direction) {
                ForEach(StreetnavDirection.allCases) { direction in
                    Text(direction.rawValue).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            .background(.bar)

            Group {
                switch direction {
                case .quietPrecision: QuietPrecisionHomeDirection()
                case .streetPulse: StreetPulseHomeDirection()
                case .completionHunt: CompletionHuntHomeDirection()
                case .rideFocus: RideFocusHomeDirection()
                case .nightExplorer: NightExplorerHomeDirection()
                case .recommended: StreetnavRecommendedView()
                }
            }
        }
    }
}

struct QuietPrecisionHomeDirection: View {
    @StateObject private var model = StreetnavPrototypeViewModel()
    @State private var expanded = false

    var body: some View {
        ZStack {
            StreetnavMapSurface(segments: model.streets, route: expanded ? model.route : nil, mode: .home, tuning: model.tuning, muted: false)
            VStack {
                HStack {
                    StreetnavSearchCapsule(text: "Rechercher autour du Canal") { expanded.toggle() }
                    StreetnavFloatingControl(symbolName: "person.crop.circle", label: "Compte")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                StreetnavBottomCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Autour de toi")
                                .font(.title2.weight(.bold))
                            Text("12,4 km de rues encore a decouvrir")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { expanded.toggle() } label: {
                            Image(systemName: expanded ? "chevron.down" : "chevron.up")
                                .frame(width: 44, height: 44)
                        }
                    }
                    if expanded {
                        HStack {
                            StreetnavRouteMetric(title: "gain", value: "+1,9%", symbolName: "chart.line.uptrend.xyaxis")
                            StreetnavRouteMetric(title: "boucle", value: "42 min", symbolName: "clock")
                        }
                        StreetnavPrimaryAction(title: "Explorer", symbolName: "bicycle") {}
                    }
                }
                .padding(12)
            }
        }
        .task { await model.load() }
    }
}

struct StreetPulseHomeDirection: View {
    @StateObject private var model = StreetnavPrototypeViewModel()
    @State private var panelOpen = false

    var body: some View {
        ZStack {
            StreetnavMapSurface(segments: model.streets, route: panelOpen ? model.route : nil, mode: .home, tuning: model.tuning, muted: false)
            VStack {
                HStack {
                    StreetnavStatusPill(title: "Live", symbolName: "dot.radiowaves.left.and.right", tint: .green, detail: "Paris 11e")
                    Spacer()
                    StreetnavFloatingControl(symbolName: "bell", label: "Alertes")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                Spacer()
                Button { panelOpen.toggle() } label: {
                    Label("Creer une sortie", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .frame(minHeight: 58)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(radius: 18, y: 8)
                }
                .accessibilityLabel("Creer une sortie d'exploration")
                .padding(.bottom, panelOpen ? 12 : 84)
                if panelOpen {
                    StreetnavBottomCard {
                        Text("Street Pulse")
                            .font(.title2.weight(.bold))
                        Text("38 rues proches a completer. Watch prete, VanMoof detecte.")
                            .foregroundStyle(.secondary)
                        StreetnavPrimaryAction(title: "Explorer 45 min", symbolName: "bicycle") {}
                    }
                    .padding(12)
                }
            }
            VStack(spacing: 12) {
                StreetnavFloatingControl(symbolName: "location.fill", label: "Recentrer")
                StreetnavFloatingControl(symbolName: "square.3.layers.3d", label: "Couches")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
        }
        .task { await model.load() }
    }
}

struct CompletionHuntHomeDirection: View {
    @StateObject private var model = StreetnavPrototypeViewModel()
    @State private var completedPulse = false

    var body: some View {
        ZStack {
            StreetnavMapSurface(segments: model.streets, route: model.route, mode: completedPulse ? .completedNewStreet : .home, tuning: model.tuning, muted: false)
            VStack {
                HStack {
                    StreetnavExplorationBadge(area: model.area)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer()
                    StreetnavFloatingControl(symbolName: "scope", label: "Objectif")
                }
                .padding(16)
                Spacer()
                StreetnavBottomCard {
                    Text("Chasse aux rues")
                        .font(.title2.weight(.bold))
                    Text("+1,9% Wandrer estime si tu termines la boucle Canal - Nation.")
                        .foregroundStyle(.secondary)
                    ProgressView(value: model.area.completion)
                        .tint(.green)
                    HStack {
                        StreetnavPrimaryAction(title: completedPulse ? "Rue ajoutee" : "Simuler une rue", symbolName: "checkmark.seal") { completedPulse.toggle() }
                        Button("Explorer") {}
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                .scaleEffect(completedPulse ? 1.015 : 1)
                .padding(12)
            }
        }
        .task { await model.load() }
    }
}

struct RideFocusHomeDirection: View {
    @StateObject private var model = StreetnavPrototypeViewModel()
    @State private var readyOpen = false

    var body: some View {
        ZStack {
            StreetnavMapSurface(segments: model.streets, route: model.route, mode: .home, tuning: model.tuning, muted: true)
            VStack {
                Spacer()
                StreetnavBottomCard {
                    Text("Pret a rouler")
                        .font(.title2.weight(.bold))
                    StreetnavDeviceStatusRow(title: model.watch.name, subtitle: "entrainement pret", state: model.watch.state)
                    StreetnavDeviceStatusRow(title: model.bike.name, subtitle: "detecte proche", state: model.bike.state, trailing: "76%")
                    if readyOpen {
                        HStack {
                            StreetnavRouteMetric(title: "duree", value: "42 min", symbolName: "clock")
                            StreetnavRouteMetric(title: "nouvelles rues", value: "3,1 km", symbolName: "sparkle")
                            StreetnavRouteMetric(title: "qualite", value: "haute", symbolName: "checkmark.seal")
                        }
                    }
                    StreetnavPrimaryAction(title: readyOpen ? "Demarrer" : "Verifier la sortie", symbolName: readyOpen ? "play.fill" : "checklist") { readyOpen.toggle() }
                }
                .padding(12)
            }
        }
        .task { await model.load() }
    }
}

struct NightExplorerHomeDirection: View {
    @StateObject private var model = StreetnavPrototypeViewModel()
    @State private var panelOpen = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StreetnavMapSurface(segments: model.streets, route: model.route, mode: .navigating, tuning: model.tuning, muted: true)
                .colorScheme(.dark)
                .opacity(0.92)
            VStack {
                HStack {
                    StreetnavSearchCapsule(text: "Explorer ce soir") { panelOpen.toggle() }
                    StreetnavFloatingControl(symbolName: "moon.stars.fill", label: "Mode nuit", isSelected: true)
                }
                .padding(16)
                Spacer()
                StreetnavBottomCard {
                    Text("Night Explorer")
                        .font(.title2.weight(.bold))
                    Text("Contraste eleve, rues manquantes lisibles sans surcharge.")
                        .foregroundStyle(.secondary)
                    if panelOpen {
                        HStack {
                            StreetnavRouteMetric(title: "arrivee", value: "20:47", symbolName: "clock")
                            StreetnavRouteMetric(title: "pistes", value: "72%", symbolName: "bicycle")
                        }
                    }
                    StreetnavPrimaryAction(title: "Explorer", symbolName: "bicycle") { panelOpen.toggle() }
                }
                .padding(12)
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }
}
