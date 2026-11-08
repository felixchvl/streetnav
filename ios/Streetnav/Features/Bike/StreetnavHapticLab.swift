import CoreHaptics
import SwiftUI
import UIKit
import os

/// The lock's vibration once it is let go past the mark. By default VanMoof's: its app plays two medium impacts that land
/// at the same instant and add up, which two Core Haptics taps at intensity 0.7 and sharpness 0.7, in one pattern, match
/// within 3 % on each of the kernel's measures (energy, amplitude, slew, displacement; 8 and 9 Nov 2026). The others are
/// left to compare: iOS's success once the bike opens, and UIKit's impacts alone or twice.
enum StreetnavUnlockHaptic: String, CaseIterable, Identifiable {
    case vanmoof
    case success
    case light, medium, heavy, soft, rigid
    case doubleLight, doubleMedium, doubleHeavy, doubleSoft, doubleRigid
    case tripleMedium

    /// A new key for the VanMoof default, rather than a choice made among the trials before it.
    static let key = "streetnav.unlockHaptic.v2"
    /// The time between the three medium impacts of `tripleMedium`, in seconds, set in the laboratory.
    static let gapKey = "streetnav.unlockHaptic.gap"
    static let defaultGap = 0.06
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vanmoof: "Comme VanMoof"
        case .success: "Succès d'iOS (après l'ouverture)"
        case .light: "Impact léger"
        case .medium: "Impact moyen"
        case .heavy: "Impact lourd"
        case .soft: "Impact souple"
        case .rigid: "Impact rigide"
        case .doubleLight: "Impact léger ×2"
        case .doubleMedium: "Impact moyen ×2"
        case .doubleHeavy: "Impact lourd ×2"
        case .doubleSoft: "Impact souple ×2"
        case .doubleRigid: "Impact rigide ×2"
        case .tripleMedium: "Impact moyen ×3, espacés"
        }
    }

    private var style: UIImpactFeedbackGenerator.FeedbackStyle? {
        switch self {
        case .light, .doubleLight: .light
        case .medium, .doubleMedium: .medium
        case .heavy, .doubleHeavy: .heavy
        case .soft, .doubleSoft: .soft
        case .rigid, .doubleRigid: .rigid
        default: nil
        }
    }

    private var count: Int { rawValue.hasPrefix("double") ? 2 : 1 }

    /// Ready to play without delay: the haptic engine started while the lock slides.
    @MainActor func prepare() {
        if self == .vanmoof { StreetnavHapticEngine.shared.prepare() }
    }

    /// Nothing for `success`, which the lock plays itself once the bike confirms.
    @MainActor func play() {
        if self == .tripleMedium {
            let stored = UserDefaults.standard.double(forKey: Self.gapKey)
            let gap = stored > 0 ? stored : Self.defaultGap
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            Task { @MainActor in
                for index in 0..<3 {
                    generator.impactOccurred()
                    generator.prepare()
                    if index < 2 { try? await Task.sleep(for: .seconds(gap)) }
                }
            }
            return
        }
        if self == .vanmoof {
            let tap = StreetnavHapticEngine.tap(0.7, 0.7)
            StreetnavHapticEngine.shared.playTogether([tap, tap], separatePlayers: false)
            return
        }
        guard let style else { return }
        let generators = (0..<count).map { _ in UIImpactFeedbackGenerator(style: style) }
        generators.forEach { $0.prepare() }
        generators.forEach { $0.impactOccurred() }
    }
}

private let hapticLog = Logger(subsystem: "com.felixchevalier.streetnav", category: "haptics")

/// Réglages › Laboratoire haptique, in development builds: every sensation the Taptic Engine can give, to feel them before
/// choosing the lock's. iOS's ready-made feedback, impacts by weight and by texture, then Core Haptics: a tap and a
/// continuous vibration set by hand, a few patterns, and a track whose vibration follows the finger.
struct StreetnavHapticLab: View {
    @ObservedObject private var engine = StreetnavHapticEngine.shared
    @State private var feedback: SensoryFeedback?
    @State private var plays = 0
    @State private var impactIntensity = 1.0
    @State private var intensity = 1.0
    @State private var sharpness = 0.5
    @State private var duration = 0.6
    @AppStorage(StreetnavUnlockHaptic.key) private var unlockHaptic = StreetnavUnlockHaptic.vanmoof
    @AppStorage(StreetnavUnlockHaptic.gapKey) private var gap = StreetnavUnlockHaptic.defaultGap
    @State private var measuring = false

    private struct Ready: Identifiable {
        let name: String
        let code: String
        let feedback: SensoryFeedback
        var id: String { code }
    }

    private static let ready: [Ready] = [
        Ready(name: "Succès", code: "success", feedback: .success),
        Ready(name: "Avertissement", code: "warning", feedback: .warning),
        Ready(name: "Erreur", code: "error", feedback: .error),
        Ready(name: "Sélection", code: "selection", feedback: .selection),
        Ready(name: "Hausse", code: "increase", feedback: .increase),
        Ready(name: "Baisse", code: "decrease", feedback: .decrease),
        Ready(name: "Début", code: "start", feedback: .start),
        Ready(name: "Fin", code: "stop", feedback: .stop),
        Ready(name: "Palier", code: "levelChange", feedback: .levelChange),
        Ready(name: "Alignement", code: "alignment", feedback: .alignment),
        Ready(name: "Tracé terminé", code: "pathComplete", feedback: .pathComplete),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Vibration du cadenas", selection: $unlockHaptic) {
                    ForEach(StreetnavUnlockHaptic.allCases) { Text($0.title).tag($0) }
                }
                ForEach(StreetnavUnlockHaptic.allCases.filter { $0 != .success }) { choice in
                    Button { mark(choice.rawValue); choice.play() } label: { row(choice.title, choice.rawValue) }
                }
                LabeledContent {
                    HStack {
                        Slider(value: $gap, in: 0.01...0.3, step: 0.005)
                        Text("\(Int((gap * 1000).rounded())) ms")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                } label: {
                    Text("Écart ×3")
                }
                Button(measuring ? "Mesure en cours…" : "Mesurer les coups superposés, 3 s d'écart") { measureAll() }
                    .disabled(measuring)
            } header: {
                Text("Cadenas, façon VanMoof")
            } footer: {
                Text("« Comme VanMoof » : deux coups superposés, intensité 0,7, netteté 0,7, mesurés à 3 % de l'app VanMoof. Le choix vaut pour le grand cadenas, quand il est lâché au-delà du trait.")
            }

            Section {
                ForEach(Self.ready) { item in
                    Button { play(item.feedback) } label: { row(item.name, item.code) }
                }
            } header: {
                Text("Retours d'iOS")
            } footer: {
                Text("Certains sont pensés pour la montre ou l'iPad : ils peuvent être faibles ou muets sur l'iPhone.")
            }

            Section {
                Button { play(.impact(weight: .light, intensity: impactIntensity)) } label: { row("Léger", "light") }
                Button { play(.impact(weight: .medium, intensity: impactIntensity)) } label: { row("Moyen", "medium") }
                Button { play(.impact(weight: .heavy, intensity: impactIntensity)) } label: { row("Lourd", "heavy") }
                Button { play(.impact(flexibility: .soft, intensity: impactIntensity)) } label: { row("Souple", "soft") }
                Button { play(.impact(flexibility: .solid, intensity: impactIntensity)) } label: { row("Ferme", "solid") }
                Button { play(.impact(flexibility: .rigid, intensity: impactIntensity)) } label: { row("Rigide", "rigid") }
                slider("Intensité", value: $impactIntensity)
            } header: {
                Text("Impacts")
            } footer: {
                Text("Un seul coup, par poids ou par texture.")
            }

            Section {
                slider("Intensité", value: $intensity)
                slider("Netteté", value: $sharpness)
                slider("Durée", value: $duration, in: 0.1...2, unit: "s")
                Button("Coup") { engine.play([StreetnavHapticEngine.tap(intensity, sharpness)]) }
                Button("Vibration continue") {
                    engine.play([StreetnavHapticEngine.buzz(intensity, sharpness, for: duration)])
                }
            } header: {
                Text("Sur mesure")
            } footer: {
                Text(engine.supported
                     ? "Core Haptics. Netteté : 0 sourd et rond, 1 sec et cliquetant."
                     : "Cet appareil n'a pas de Taptic Engine (le simulateur n'en a pas).")
            }

            Section {
                Button("Cran de cadenas") { engine.notch() }
                Button("Clac de serrure") { engine.latch() }
                Button("Grondement qui monte") { engine.rumbleUp() }
                Button("Battement de cœur") { engine.heartbeat() }
                Button("Cliquet") { engine.ratchet() }
                Button("Moteur") { engine.motor() }
            } header: {
                Text("Motifs")
            }

            Section {
                StreetnavHapticTrack(began: engine.followBegan, changed: engine.follow, ended: engine.followEnded)
                    .frame(height: 56)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } header: {
                Text("Suivre le doigt")
            } footer: {
                Text("La vibration monte avec la course, un cran quand tu passes le trait à 72 %, et un clac si tu lâches au-delà : ce que le cadenas pourrait faire.")
            }
        }
        .navigationTitle("Laboratoire haptique")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(trigger: plays) { _, _ in feedback }
    }

    /// A mark in the system log before each sound, to tell the plays apart in a capture.
    private func mark(_ name: String) {
        hapticLog.notice("haptic-lab \(name, privacy: .public)")
    }

    /// Two taps at the same instant, by intensity then sharpness: the grid the measuring run goes through.
    private static let grid: [(intensity: Double, sharpness: Double)] = [0.5, 0.6, 0.7, 0.8].flatMap { intensity in
        [0.4, 0.7, 1].map { (intensity, $0) }
    }

    /// UIKit's medium impact for reference, then each pair of taps of the grid, the engine stopped after each so that the
    /// kernel measures them one by one (left running, it measures them all as one).
    private func measureAll() {
        measuring = true
        Task {
            mark("medium")
            StreetnavUnlockHaptic.medium.play()
            try? await Task.sleep(for: .seconds(3))
            for cell in Self.grid {
                mark("ch2_i\(Int(cell.intensity * 100))_s\(Int(cell.sharpness * 100))")
                let tap = StreetnavHapticEngine.tap(cell.intensity, cell.sharpness)
                engine.playTogether([tap, tap], separatePlayers: false)
                try? await Task.sleep(for: .seconds(0.8))
                engine.stopNow()
                try? await Task.sleep(for: .seconds(2.2))
            }
            measuring = false
        }
    }

    private func play(_ value: SensoryFeedback) {
        feedback = value
        plays += 1
    }

    private func row(_ name: String, _ code: String) -> some View {
        LabeledContent {
            Text(code).font(.footnote.monospaced())
        } label: {
            Text(name).foregroundStyle(.primary)
        }
    }

    private func slider(_ name: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1, unit: String = "") -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: range)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))) + (unit.isEmpty ? "" : " \(unit)"))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        } label: {
            Text(name)
        }
    }
}

/// A track to drag across: a lock that follows the finger, the 72 % mark of the real lock, filled as it goes.
private struct StreetnavHapticTrack: View {
    let began: () -> Void
    let changed: (Double) -> Void
    let ended: () -> Void
    @State private var progress = 0.0
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let knob = geometry.size.height
            let travel = max(1, geometry.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.green.opacity(0.12 + 0.7 * progress))
                Capsule()
                    .fill(.secondary)
                    .frame(width: 2, height: knob * 0.4)
                    .offset(x: knob / 2 + travel * 0.72)
                Image(systemName: progress >= 0.72 ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: knob, height: knob)
                    .streetnavGlass(in: Circle())
                    .offset(x: travel * progress)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == false {
                            dragging = true
                            began()
                        }
                        progress = min(1, max(0, (value.location.x - knob / 2) / travel))
                        changed(progress)
                    }
                    .onEnded { _ in
                        dragging = false
                        ended()
                        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { progress = 0 }
                    }
            )
        }
        .accessibilityLabel("Piste d'essai")
    }
}

/// Core Haptics for the laboratory: patterns made of taps (transient events) and vibrations (continuous events), each with
/// an intensity and a sharpness, and one player whose intensity and sharpness are changed live.
@MainActor
final class StreetnavHapticEngine: ObservableObject {
    static let shared = StreetnavHapticEngine()
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var follower: CHHapticAdvancedPatternPlayer?
    private var armed = false

    private func started() -> CHHapticEngine? {
        if let engine { return engine }
        guard supported, let made = try? CHHapticEngine() else { return nil }
        made.isAutoShutdownEnabled = true
        // Stopped or reset by the system (the app sent back, audio taken): made again on the next play.
        made.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.forget() } }
        made.resetHandler = { [weak self] in Task { @MainActor in self?.forget() } }
        do {
            try made.start()
        } catch {
            return nil
        }
        engine = made
        return made
    }

    private func forget() {
        engine = nil
        follower = nil
    }

    func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = []) {
        guard let engine = started(),
              let pattern = try? CHHapticPattern(events: events, parameterCurves: curves),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? engine.start()
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    /// Started ahead, so that the next pattern plays at once.
    func prepare() { _ = started() }

    /// Stops the engine at once, so that the system closes its haptics session.
    func stopNow() {
        engine?.stop()
        forget()
    }

    /// The events at the very same instant: in one pattern, or each in its own player started at the same engine time.
    func playTogether(_ events: [CHHapticEvent], separatePlayers: Bool) {
        guard separatePlayers else { return play(events) }
        guard let engine = started() else { return }
        try? engine.start()
        let players = events.compactMap { event in
            (try? CHHapticPattern(events: [event], parameters: [])).flatMap { try? engine.makePlayer(with: $0) }
        }
        let at = engine.currentTime + 0.03
        players.forEach { try? $0.start(atTime: at) }
    }

    static func tap(_ intensity: Double, _ sharpness: Double, at time: TimeInterval = 0) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
        ], relativeTime: time)
    }

    static func buzz(_ intensity: Double, _ sharpness: Double, at time: TimeInterval = 0, for duration: TimeInterval,
                     attack: Double = 0, release: Double = 0.05) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
            CHHapticEventParameter(parameterID: .attackTime, value: Float(attack)),
            CHHapticEventParameter(parameterID: .releaseTime, value: Float(release)),
        ], relativeTime: time, duration: duration)
    }

    private static func intensityCurve(_ points: [(TimeInterval, Double)]) -> CHHapticParameterCurve {
        CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                               controlPoints: points.map { .init(relativeTime: $0.0, value: Float($0.1)) },
                               relativeTime: 0)
    }

    // MARK: Patterns

    /// A notch: one hard, dry tap with a dull one right behind it.
    func notch() { play([Self.tap(1, 1), Self.tap(0.7, 0.3, at: 0.02)]) }

    /// A lock opening: a light dry click, then a heavy dull clunk with a short tail.
    func latch() {
        play([Self.tap(0.6, 1), Self.tap(1, 0.2, at: 0.09), Self.buzz(0.45, 0.1, at: 0.09, for: 0.12)])
    }

    /// A rumble growing from faint to full over 1.2 s.
    func rumbleUp() {
        play([Self.buzz(1, 0.3, for: 1.2)], curves: [Self.intensityCurve([(0, 0.1), (1.2, 1)])])
    }

    /// Two beats, twice.
    func heartbeat() {
        play([Self.tap(1, 0.3), Self.tap(0.6, 0.2, at: 0.15), Self.tap(1, 0.3, at: 0.9), Self.tap(0.6, 0.2, at: 1.05)])
    }

    /// Twelve dry clicks, faster and harder.
    func ratchet() {
        play((0..<12).map { Self.tap(0.45 + 0.05 * Double($0), 0.9, at: Double($0) * (0.075 - 0.003 * Double($0))) })
    }

    /// A low vibration throbbing ten times a second.
    func motor() {
        let points = (0...15).map { (Double($0) * 0.1, $0.isMultiple(of: 2) ? 1.0 : 0.35) }
        play([Self.buzz(0.8, 0.05, for: 1.5)], curves: [Self.intensityCurve(points)])
    }

    // MARK: Following the finger

    func followBegan() {
        guard let engine = started(),
              let pattern = try? CHHapticPattern(events: [Self.buzz(1, 0.3, for: 30)], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        follower = player
        armed = false
        try? engine.start()
        try? player.start(atTime: CHHapticTimeImmediate)
        follow(0)
    }

    /// Stronger and sharper as the finger goes; the notch once past the mark, either way.
    func follow(_ progress: Double) {
        try? follower?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(0.12 + 0.88 * progress), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(0.15 + 0.6 * progress), relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
        let past = progress >= 0.72
        if past != armed {
            armed = past
            notch()
        }
    }

    func followEnded() {
        try? follower?.stop(atTime: CHHapticTimeImmediate)
        follower = nil
        if armed { latch() }
        armed = false
    }
}
