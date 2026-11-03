import CoreLocation
import SwiftUI

/// Réglages › VanMoof S6: the VanMoof account that issues the bike's certificate, then the bike itself over Bluetooth.
struct StreetnavVanMoofView: View {
    @ObservedObject private var account = StreetnavVanMoofAccount.shared
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    @State private var email = ""
    @State private var password = ""
    @State private var unlockText: String?
    @State private var isUnlocking = false

    var body: some View {
        Form {
            accountSection
            if account.isSignedIn { bikeSection }
            Section {
                NavigationLink {
                    StreetnavVanMoofLogView()
                } label: {
                    LabeledContent("Journal Bluetooth", value: bike.log.isEmpty ? "Vide" : "\(bike.log.count) lignes")
                }
            } footer: {
                Text("Chaque étape de la connexion et chaque message échangé avec le vélo, pour voir où ça bloque.")
            }
        }
        .navigationTitle(account.bike?.name ?? "VanMoof S6")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                LabeledContent("Vélo", value: account.bike?.name ?? "—")
                LabeledContent("Certificat", value: certificateText)
                Button("Se déconnecter", role: .destructive) {
                    bike.disconnect()
                    account.signOut()
                }
            } else {
                TextField("E-mail", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                Button(account.isWorking ? "Connexion…" : "Se connecter") {
                    Task {
                        await account.signIn(email: email, password: password)
                        password = ""
                    }
                }
                .disabled(account.isWorking || email.isEmpty || password.isEmpty)
            }
            if let error = account.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            header("Compte VanMoof")
        } footer: {
            Text("Le mot de passe ne sert qu'à te connecter chez VanMoof et n'est pas gardé. Streetnav demande ensuite à VanMoof un certificat pour ton vélo, valable une semaine et renouvelé tout seul.")
        }
    }

    @ViewBuilder
    private var bikeSection: some View {
        Section {
            LabeledContent("État", value: stateText)
            if bike.state == .ready {
                LabeledContent("Batterie", value: bike.battery.map { "\($0) %" } ?? "—")
                LabeledContent("Verrou", value: bike.isLocked.map { $0 ? "Verrouillé" : "Déverrouillé" } ?? "—")
                LabeledContent("Vitesse", value: bike.speedKmh.map { "\(Int($0.rounded())) km/h" } ?? bike.speed ?? "—")
                LabeledContent("Compteur", value: bike.odometerMeters.map { "\(($0 / 1000).formatted()) km" } ?? "—")
                if let firmware = bike.firmware { LabeledContent("Logiciel", value: firmware) }
                Button("Actualiser") { bike.refresh() }
            } else if bike.state == .idle || bike.state.isFailure {
                Button("Se connecter au vélo") { Task { await bike.connect() } }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(stateText).foregroundStyle(.secondary)
                }
            }
        } header: {
            header("Vélo")
        } footer: {
            if bike.state == .ready {
                Text(bike.speedKmh == nil
                     ? "La vitesse est la valeur que le vélo envoie : son unité se règle toute seule à la première navigation, en la comparant au GPS."
                     : "Vitesse du vélo, en km/h.")
            }
        }
        // The speed again twice a second while the screen is open.
        .task(id: bike.state == .ready) {
            while bike.state == .ready, Task.isCancelled == false {
                bike.refreshSpeed()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        if bike.state == .ready { settingsSections }

        Section {
            Button {
                Task {
                    isUnlocking = true
                    unlockText = await bike.unlock() ? "Vélo déverrouillé." : "Le vélo n'a pas confirmé le déverrouillage."
                    isUnlocking = false
                }
            } label: {
                // Text alone, centred: a padlock beside it pulled it off the middle.
                Text(isUnlocking ? "Déverrouillage…" : "Déverrouiller")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isUnlocking)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if let unlockText {
                Text(unlockText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Le vélo se verrouille sur lui-même, avec la béquille : il n'y a pas de commande pour le verrouiller. Ferme l'app VanMoof avant, le vélo n'accepte qu'une connexion à la fois.")
        }
    }

    /// What the bike lets Streetnav change, each read back from it once set.
    @ViewBuilder
    private var settingsSections: some View {
        Section {
            Picker("Assistance", selection: setting(bike.assistLevel, bike.setAssistLevel)) {
                Text("Désactivée").tag(0)
                Text("Éco").tag(1)
                Text("Normale").tag(2)
                Text("Sport").tag(3)
                Text("Turbo").tag(4)
            }
            .disabled(bike.assistLevel == nil)
            Picker("Phares", selection: setting(bike.lightMode, bike.setLightMode)) {
                Text("Éteints").tag(0)
                Text("Allumés").tag(2)
                Text("Automatiques").tag(3)
            }
            .disabled(bike.lightMode == nil)
            Button("Sonner") { bike.ringBell() }
        } header: {
            header("Conduite")
        }

        Section {
            Toggle("Alarme", isOn: Binding(get: { bike.alarmOn ?? false }, set: { bike.setAlarm($0) }))
                .disabled(bike.alarmOn == nil)
            Picker("Sensibilité", selection: setting(bike.alarmSensitivity, bike.setAlarmSensitivity)) {
                Text("Haute").tag(1)
                Text("Moyenne").tag(2)
                Text("Basse").tag(4)
            }
            .disabled(bike.alarmSensitivity == nil)
        } header: {
            header("Alarme")
        }

        Section {
            Picker("Limite de charge", selection: setting(bike.chargeLimit, bike.setChargeLimit)) {
                ForEach([80, 85, 90, 95, 100], id: \.self) { Text("\($0) %").tag($0) }
            }
            .disabled(bike.chargeLimit == nil)
        } header: {
            header("Batterie")
        } footer: {
            Text("Charger à 80 % ménage la batterie au quotidien ; 100 % pour une longue sortie.")
        }

        Section {
            LabeledContent("Erreurs", value: errorsText)
            LabeledContent("État du moteur", value: bike.motorState ?? "—")
            LabeledContent("État de veille", value: bike.wakeState ?? "—")
            LabeledContent("Mode de sonnette", value: bike.bellMode ?? "—")
            LabeledContent("Intervalle des notifications", value: bike.notifyInterval ?? "—")
        } header: {
            header("Diagnostic")
        } footer: {
            Text("Valeurs telles que le vélo les envoie : leur sens n'est pas documenté, Streetnav ne les modifie pas.")
        }
    }

    /// A setting the bike reported, written back when changed; 0 until the bike has answered (the control is off).
    private func setting(_ value: Int?, _ write: @escaping (Int) -> Void) -> Binding<Int> {
        Binding(get: { value ?? 0 }, set: { write($0) })
    }

    /// Each trouble code as its device and code, as the official app shows them by number.
    private var errorsText: String {
        guard let codes = bike.errorCodes else { return "—" }
        guard codes.isEmpty == false else { return "Aucune" }
        return codes.map { code in
            let device = StreetnavVanMoofProtocol.errorDevices[code >> 8] ?? String(format: "appareil %02X", code >> 8)
            return "\(device) \(String(format: "%04X", code))"
        }.joined(separator: ", ")
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var certificateText: String {
        guard let expiry = account.certificateExpiry else { return "—" }
        return expiry > .now ? "Jusqu'au \(expiry.formatted(date: .abbreviated, time: .shortened))" : "Expiré"
    }

    private var stateText: String {
        switch bike.state {
        case .idle: "Non connecté"
        case .searching: "Recherche du vélo…"
        case .connecting: "Connexion…"
        case .authenticating: "Authentification…"
        case .ready: "Connecté"
        case .failed(let reason): reason
        }
    }
}

/// The bike on the map, as Maps shows the weather: its battery in a glass chip, and a lock while it is locked, only
/// while the bike is connected; a tap unlocks it or rings the bell. The assistance and the lights are left to the bike's
/// settings.
struct StreetnavBikeChip: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared

    var body: some View {
        if bike.state == .ready {
            Menu {
                if bike.isLocked != false {
                    Button("Déverrouiller", systemImage: "lock.open") { Task { await bike.unlock() } }
                }
                Button("Sonner", systemImage: "bell") { bike.ringBell() }
            } label: {
                HStack(spacing: 10) {
                    StreetnavBikeBattery(percent: bike.battery)
                    if bike.isLocked == true {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("verrouillé")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .streetnavGlass(in: Capsule(), interactive: true)
            }
            // The menu would tint its label with the accent.
            .tint(.primary)
            .accessibilityLabel("Vélo")
            // Battery and lock now and then while it shows.
            .task {
                while Task.isCancelled == false {
                    bike.refreshStatus()
                    try? await Task.sleep(for: .seconds(20))
                }
            }
        }
    }
}

/// The battery as an icon filled to its level, and its percent.
struct StreetnavBikeBattery: View {
    let percent: Int?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(colour)
            Text(percent.map { "\($0) %" } ?? "—")
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Batterie \(percent.map { "\($0) %" } ?? "inconnue")")
    }

    /// Amber when low, red when nearly empty, as in the navigation's dial.
    private var colour: Color {
        switch percent ?? 100 {
        case ...10: .red
        case ...20: .orange
        default: .secondary
        }
    }

    private var symbol: String {
        switch percent ?? 100 {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// The names Streetnav gives the bike's settings.
enum StreetnavBikeLabels {
    static let assistLevels: [(level: Int, name: String)] = [(0, "Désactivée"), (1, "Éco"), (2, "Normale"), (3, "Sport"), (4, "Turbo")]
    static let lightModes: [(mode: Int, name: String)] = [(3, "Automatiques"), (2, "Allumés"), (0, "Éteints")]

    static func assistName(_ level: Int) -> String {
        assistLevels.first { $0.level == level }?.name ?? "—"
    }

    static func lightName(_ mode: Int?) -> String {
        lightModes.first { $0.mode == mode }?.name ?? "inconnus"
    }

    static func lightSymbol(_ mode: Int?) -> String {
        switch mode {
        case 2: "lightbulb.fill"
        case 0: "lightbulb.slash"
        default: "lightbulb.max"
        }
    }
}

/// The Bluetooth journal: each step of the connection and each message with the bike, newest at the bottom, to share.
struct StreetnavVanMoofLogView: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared

    var body: some View {
        ScrollViewReader { proxy in
            List(bike.log) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .listStyle(.plain)
            .overlay {
                if bike.log.isEmpty {
                    ContentUnavailableView("Journal vide", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Il se remplit dès que Streetnav se connecte au vélo."))
                }
            }
            .onAppear { if let last = bike.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: bike.log.count) { if let last = bike.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .navigationTitle("Journal Bluetooth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: bike.logText) { Image(systemName: "square.and.arrow.up") }
                    .disabled(bike.log.isEmpty)
                Button("Effacer", systemImage: "trash") { bike.clearLog() }
                    .disabled(bike.log.isEmpty)
            }
        }
    }
}
