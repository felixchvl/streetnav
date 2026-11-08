import CoreHaptics
import SwiftUI

/// Réglages › Laboratoire haptique, in development builds: every sensation the Taptic Engine can give, to feel them before
/// choosing the lock's. iOS's ready-made feedback, impacts by weight and by texture, then Core Haptics: a tap and a
/// continuous vibration set by hand, a few patterns, and a track whose vibration follows the finger.
struct StreetnavHapticLab: View {
    @StateObject private var engine = StreetnavHapticEngine()
    @State private var feedback: SensoryFeedback?
    @State private var plays = 0
    @State private var impactIntensity = 1.0
    @State private var intensity = 1.0
    @State private var sharpness = 0.5
    @State private var duration = 0.6

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
