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
            // The result right under the capsule, on the same bare row: no card of its own with other corners.
            VStack(spacing: 8) {
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
                .disabled(isUnlocking)
                if let unlockText {
                    Text(unlockText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: unlockText)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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

/// The bike on the map, as Maps shows the weather: the lock to slide down while the bike is locked (or not connected
/// yet), then its battery in a glass chip once connected; a tap on the battery unlocks it or rings the bell. The
/// assistance and the lights are left to the bike's settings.
struct StreetnavBikeChip: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    @ObservedObject private var account = StreetnavVanMoofAccount.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if account.isSignedIn || bike.state == .ready {
                StreetnavUnlockSlider()
            }
            if bike.state == .ready {
                status
            }
        }
    }

    private var status: some View {
        Menu {
            if bike.isLocked != false {
                Button("Déverrouiller", systemImage: "lock.open") { Task { await bike.unlock() } }
            }
            Button("Sonner", systemImage: "bell") { bike.ringBell() }
        } label: {
            StreetnavBikeBattery(percent: bike.battery)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: StreetnavUnlockSlider.chipHeight)
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

/// The screen the app opens on while the bike may be locked: the lock, large, to slide down, over the map dimmed behind
/// it; « Explorer la carte » leaves it for the map. It goes by itself once the bike reports its lock open.
struct StreetnavStartScreen: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    @ObservedObject private var account = StreetnavVanMoofAccount.shared
    let explore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(account.bike?.name ?? "Ton vélo")
                    .font(.largeTitle.weight(.bold))
                HStack(spacing: 10) {
                    if bike.state == .ready, bike.battery != nil {
                        StreetnavBikeBattery(percent: bike.battery)
                    }
                    Text(status)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)

            Spacer(minLength: 24)
            // The track hangs below the lock: room for it, then the way to go.
            StreetnavUnlockSlider(large: true)
                .frame(height: 104 + 232, alignment: .top)
            Text("Glisse le cadenas vers le bas")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .opacity(bike.isLocked == false ? 0 : 1)
            Spacer(minLength: 24)

            Button(action: explore) {
                Label("Explorer la carte", systemImage: "map")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Capsule())
                    .streetnavGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The map stays in sight, darker where the words are.
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.25), .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .task { if bike.state == .idle { await bike.connect() } }
    }

    private var status: String {
        switch bike.state {
        case .idle: "Non connecté"
        case .searching: "Recherche du vélo…"
        case .connecting: "Connexion…"
        case .authenticating: "Authentification…"
        case .ready: bike.isLocked == false ? "Déverrouillé" : "Verrouillé"
        case .failed(let reason): reason
        }
    }
}

/// The lock to slide down, as in VanMoof's app: it follows the finger down its track, at the screen's full rate (120 Hz
/// on ProMotion), opens past three quarters of the way, and unlocks the bike once let go there; let go sooner, it
/// springs back. At rest it is a single round button that leaves the map in sight, and nudges down now and then.
struct StreetnavUnlockSlider: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// VanMoof's hit when let go past the mark, unless another is chosen in the haptics laboratory.
    @AppStorage(StreetnavUnlockHaptic.key) private var unlockHaptic = StreetnavUnlockHaptic.vanmoof

    private enum Phase { case resting, sliding, unlocking, unlocked, failed }

    @State private var phase = Phase.resting
    /// How far down the lock is, in points.
    @State private var offset: CGFloat = 0
    @State private var failure: String?
    @State private var successes = 0
    @State private var failures = 0

    /// The small lock's size on the map, and the battery chip's height beside it.
    static let chipHeight: CGFloat = 44

    /// Small on the map, large on the start screen.
    private let large: Bool
    /// The lock's size.
    private let knob: CGFloat
    /// How far it slides.
    private let travel: CGFloat

    init(large: Bool = false) {
        self.large = large
        knob = large ? 104 : Self.chipHeight
        travel = large ? 232 : 128
    }
    /// The share of the way past which letting go unlocks.
    static let threshold: CGFloat = 0.72

    private var progress: CGFloat { min(1, offset / travel) }
    private var armed: Bool { progress >= Self.threshold }
    private var opening: Bool { armed || phase == .unlocking || phase == .unlocked }

    /// Why it failed, or, while the bike sleeps through an unlock, how to wake it.
    private var caption: String? {
        if let failure { return failure }
        return phase == .unlocking && bike.isAsleep == true ? "Le vélo dort : appuie sur un bouton du guidon." : nil
    }

    var body: some View {
        if bike.isLocked != false || phase != .resting {
            ZStack(alignment: .top) {
                // Large, the way down shows at rest too: where to slide is plain.
                if large || phase == .sliding || phase == .unlocking || phase == .unlocked {
                    track
                        .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .top)))
                }
                knobView
                    .offset(y: offset)
            }
            // Only the lock takes room: the track hangs below, over the map.
            .frame(width: knob, height: knob, alignment: .top)
            .overlay(alignment: large ? .top : .topLeading) {
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .streetnavGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        // As wide as its words, up to 240 points, beyond the lock's own width.
                        .frame(width: 240, alignment: large ? .center : .leading)
                        // Below the lock, or below the track while it is down.
                        .offset(y: knob + 8 + (phase == .unlocking ? travel : 0))
                        .transition(.opacity)
                }
            }
            // A tick when the lock would open, or would no longer, under the finger.
            .sensoryFeedback(.selection, trigger: armed) { _, _ in phase == .sliding }
            .sensoryFeedback(trigger: successes) { _, _ in unlockHaptic == .success ? .success : nil }
            .sensoryFeedback(.error, trigger: failures)
            .accessibilityElement()
            .accessibilityLabel(phase == .unlocking ? "Déverrouillage du vélo" : "Vélo verrouillé")
            .accessibilityHint("Glisser le cadenas vers le bas pour déverrouiller")
            .accessibilityAction(named: "Déverrouiller") { unlock() }
        }
    }

    /// The way down: filled to the lock (green once letting go would unlock), chevrons going down, the open lock at the end.
    private var track: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.green.opacity(opening ? 0.9 : 0.12 + 0.3 * progress))
                .frame(height: knob + offset)
            StreetnavDownChevrons(size: large ? 34 : 20)
                .frame(height: travel - knob)
                .padding(.top, knob)
                .opacity(phase == .sliding ? max(0, 1 - progress * 1.6) : large && phase == .resting ? 1 : 0)
            Image(systemName: "lock.open")
                .font(.system(size: knob * 0.39, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: knob, height: knob)
                .padding(.top, travel)
                .opacity(armed ? 0 : 0.8)
        }
        .frame(width: knob, height: knob + travel, alignment: .top)
        .streetnavGlass(in: Capsule())
    }

    private var knobView: some View {
        Image(systemName: opening ? "lock.open.fill" : "lock.fill")
            .font(.system(size: knob * 0.41, weight: .semibold))
            .foregroundStyle(opening ? Color.white : phase == .failed ? Color.orange : Color.primary)
            // The shackle opens as the symbol changes.
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
            // Which way to slide, now and then while it rests.
            .symbolEffect(.wiggle.down, options: .repeat(.periodic(delay: 6)), isActive: phase == .resting && reduceMotion == false)
            .symbolEffect(.pulse, isActive: phase == .unlocking)
            .symbolEffect(.bounce, value: successes)
            .symbolEffect(.wiggle, value: failures)
            .frame(width: knob, height: knob)
            .background(Circle().fill(Color.green).opacity(opening ? 1 : 0))
            .streetnavGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
            .gesture(slide)
            .onTapGesture(perform: hint)
    }

    private var slide: some Gesture {
        // Measured on the screen: the lock moves under the finger, so its own frame would move with it.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard phase == .resting || phase == .sliding || phase == .failed else { return }
                if phase != .sliding {
                    unlockHaptic.prepare()
                    withAnimation(.snappy(duration: 0.2)) {
                        phase = .sliding
                        failure = nil
                    }
                }
                // Straight under the finger, then a little resistance past the end.
                let y = max(0, value.translation.height)
                offset = y <= travel ? y : travel + min(16, (y - travel) * 0.2)
            }
            .onEnded { value in
                guard phase == .sliding else { return }
                // A flick down past the middle unlocks too.
                let flicked = progress >= 0.5 && value.predictedEndTranslation.height >= travel * 1.2
                if armed || flicked { unlock() } else { rest() }
            }
    }

    private func rest() {
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            offset = 0
            phase = .resting
        }
    }

    /// A tap shows the way: the lock dips and comes back.
    private func hint() {
        guard phase == .resting else { return }
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            phase = .sliding
            offset = 30
        }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            if phase == .sliding { rest() }
        }
    }

    private func unlock() {
        guard phase != .unlocking else { return }
        unlockHaptic.play()
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            offset = travel
            phase = .unlocking
            failure = nil
        }
        Task {
            let opened = await bike.unlock()
            if opened {
                successes += 1
                withAnimation(.snappy) { phase = .unlocked }
                try? await Task.sleep(for: .seconds(1.2))
                // The bike now reports its lock open: the slider goes.
                withAnimation(.snappy) {
                    phase = .resting
                    offset = 0
                }
            } else {
                failures += 1
                withAnimation(.spring(duration: 0.45, bounce: 0.3)) {
                    phase = .failed
                    offset = 0
                    failure = bike.isAsleep == true ? "Le vélo dort toujours : appuie sur un bouton du guidon, puis glisse à nouveau."
                        : Self.reason(bike.state)
                }
                try? await Task.sleep(for: .seconds(4))
                guard phase == .failed else { return }
                withAnimation(.snappy) {
                    phase = .resting
                    failure = nil
                }
            }
        }
    }

    private static func reason(_ state: StreetnavVanMoofBike.State) -> String {
        if case .failed(let reason) = state { return reason }
        return "Le vélo n'a pas confirmé l'ouverture."
    }
}

/// Three chevrons lighting up one after the other, downwards: the way to slide.
private struct StreetnavDownChevrons: View {
    var size: CGFloat = 20

    var body: some View {
        PhaseAnimator([0, 1, 2, 3]) { lit in
            VStack(spacing: -6) {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: "chevron.compact.down")
                        .opacity(index == lit ? 0.95 : 0.3)
                }
            }
        } animation: { _ in .easeInOut(duration: 0.22) }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
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
