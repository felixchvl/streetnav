import CoreLocation
import SwiftUI

/// The bike in the navigation, laid out like the instrument cluster of CarPlay Ultra (WWDC24, « Say hello to the next
/// generation of CarPlay design system »): the speed on a dial with the battery in its gap, as the speedometer always
/// goes with the charge; the assistance as the drive mode, a row of modes with the current one lit; telltales for the
/// lock and the lights; a trip computer for the odometer; and the unlocking as a notification, only while locked.
/// The speed is the bike's once its unit is known, the GPS's until then.
struct StreetnavBikeCluster: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    /// The rider's position from the guidance, for its speed.
    let location: CLLocation?
    /// The odometer when the navigation started, for the distance of this trip.
    @State private var startOdometer: Int?
    @State private var isUnlocking = false
    @State private var unlockFailed = false

    var body: some View {
        if bike.state == .ready {
            HStack(alignment: .center, spacing: 16) {
                StreetnavSpeedDial(speed: speed, battery: bike.battery)
                    .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 16) {
                    if bike.isLocked == true {
                        unlockNotice
                            .transition(.blurReplace)
                    } else {
                        StreetnavAssistModes(level: bike.assistLevel) { bike.setAssistLevel($0) }
                            .transition(.blurReplace)
                    }
                    HStack(alignment: .center, spacing: 0) {
                        telltales
                        Spacer(minLength: 12)
                        // The trip computer: label on the left, value on the right, as in a car.
                        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                            tripRow("Trajet", kilometres(trip, decimals: 1))
                            tripRow("Total", kilometres(bike.odometerMeters, decimals: 0))
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .animation(.snappy, value: bike.isLocked)
            .onChange(of: location) { _, location in
                if let location, location.speed >= 0 { bike.noteGPS(speedKmh: location.speed * 3.6) }
            }
            .onChange(of: bike.odometerMeters, initial: true) { _, metres in
                if startOdometer == nil { startOdometer = metres }
            }
            // The speed twice a second, the rest every ten seconds.
            .task {
                var tick = 0
                while Task.isCancelled == false {
                    bike.refreshSpeed()
                    if tick % 20 == 0 { bike.refreshStatus() }
                    tick += 1
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    // MARK: Parts

    /// In the middle, where CarPlay puts its notifications: the bike is locked, a tap unlocks it.
    private var unlockNotice: some View {
        Button {
            isUnlocking = true
            unlockFailed = false
            Task {
                unlockFailed = await bike.unlock() == false
                isUnlocking = false
            }
        } label: {
            HStack(spacing: 7) {
                if isUnlocking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "lock.open.fill")
                }
                Text(unlockFailed ? "Réessayer" : "Déverrouiller")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(isUnlocking)
    }

    /// Lit only when they matter, as in a car: the lock in amber while the bike is locked, the lights in green while
    /// they are on (an A when automatic); a tap on the lights turns them automatic, on, off.
    private var telltales: some View {
        HStack(spacing: 14) {
            Image(systemName: bike.isLocked == true ? "lock.fill" : "lock.open.fill")
                .foregroundStyle(bike.isLocked == true ? Color.orange : Color.secondary.opacity(0.45))
                .accessibilityLabel(bike.isLocked == true ? "Vélo verrouillé" : "Vélo déverrouillé")
            Button {
                let next = switch bike.lightMode {
                case 3: 2
                case 2: 0
                default: 3
                }
                bike.setLightMode(next)
            } label: {
                Image(systemName: bike.lightMode == 0 ? "headlight.low.beam" : "headlight.low.beam.fill")
                    .foregroundStyle(bike.lightMode == 0 ? Color.secondary.opacity(0.45) : Self.telltaleGreen)
                    .overlay(alignment: .bottomTrailing) {
                        if bike.lightMode == 3 {
                            Text(verbatim: "A")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Self.telltaleGreen)
                                .offset(x: 6, y: 3)
                        }
                    }
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Phares : \(StreetnavBikeLabels.lightName(bike.lightMode)), toucher pour changer")
        }
        .font(.system(size: 17, weight: .semibold))
    }

    private func tripRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Values

    private static let telltaleGreen = Color(red: 0.2, green: 0.78, blue: 0.35)
    private static let french = Locale(identifier: "fr_FR")

    private var speed: Double? {
        if let kmh = bike.speedKmh { return kmh }
        guard let location, location.speed >= 0 else { return nil }
        return location.speed * 3.6
    }

    private var trip: Int? {
        guard let start = startOdometer, let now = bike.odometerMeters else { return nil }
        return max(0, now - start)
    }

    private func kilometres(_ metres: Int?, decimals: Int) -> String {
        guard let metres else { return "—" }
        return "\((Double(metres) / 1000).formatted(.number.precision(.fractionLength(decimals)).locale(Self.french))) km"
    }
}

/// The speedometer: an arc from 0 to 40 km/h ticked every 5, lit in blue up to the speed, crossed by a line at 25 km/h
/// where the motor stops helping (as CarPlay marks the speed limiter); the speed in the middle; the battery in the gap
/// below, in amber when low and red when nearly empty.
struct StreetnavSpeedDial: View {
    let speed: Double?
    let battery: Int?

    private static let range = 40.0
    private static let assistLimit = 25.0
    /// The speed arc, from bottom left round the top to bottom right; the battery in the gap left between.
    private static let start = 150.0
    private static let sweep = 240.0
    private static let batteryArc = (from: 52.0, to: 128.0)
    private static let width: CGFloat = 9

    var body: some View {
        let fraction = min(1, max(0, (speed ?? 0) / Self.range))
        let charge = min(1, max(0, Double(battery ?? 0) / 100))
        ZStack {
            // Speed: the track, the speed reached, the ticks and the assistance limit.
            DialArc(start: Self.start, end: Self.start + Self.sweep, inset: Self.width / 2)
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: Self.width, lineCap: .round))
            DialArc(start: Self.start, end: Self.start + Self.sweep * fraction, inset: Self.width / 2)
                .stroke(AngularGradient(colors: [Self.blue.opacity(0.55), Self.blue], center: .center,
                                        startAngle: .degrees(Self.start), endAngle: .degrees(Self.start + Self.sweep * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: Self.width, lineCap: .round))
                .opacity(speed == nil ? 0 : 1)
            ticks
            // Battery, filled from the left.
            DialArc(start: Self.batteryArc.from, end: Self.batteryArc.to, inset: Self.width / 2)
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            DialArc(start: Self.batteryArc.to - (Self.batteryArc.to - Self.batteryArc.from) * charge, end: Self.batteryArc.to,
                    inset: Self.width / 2)
                .stroke(batteryColour, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .opacity(battery == nil ? 0 : 1)
            VStack(spacing: -4) {
                Text(speed.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 46, weight: .semibold).width(.condensed))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .offset(y: -8)
            Text(battery.map { "\($0) %" } ?? "—")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(battery.map { $0 <= 20 } == true ? batteryColour : Color.primary.opacity(0.75))
                .offset(y: 40)
        }
        .animation(.easeOut(duration: 0.45), value: speed.map { ($0 * 2).rounded() })
        .animation(.snappy, value: battery)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vitesse \(speed.map { "\(Int($0.rounded())) km/h" } ?? "inconnue"), batterie \(battery.map { "\($0) %" } ?? "inconnue")")
    }

    private var ticks: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - Self.width - 3
            func line(at kmh: Double, from inner: Double, to outer: Double, width: Double, colour: Color) {
                let angle = (Self.start + Self.sweep * kmh / Self.range) * .pi / 180
                var path = Path()
                path.move(to: CGPoint(x: centre.x + inner * cos(angle), y: centre.y + inner * sin(angle)))
                path.addLine(to: CGPoint(x: centre.x + outer * cos(angle), y: centre.y + outer * sin(angle)))
                context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            for kmh in stride(from: 0.0, through: Self.range, by: 5) {
                let major = kmh.truncatingRemainder(dividingBy: 10) == 0
                line(at: kmh, from: outer - (major ? 7 : 4), to: outer, width: major ? 1.6 : 1, colour: Color.primary.opacity(major ? 0.5 : 0.3))
            }
            // Where the motor stops: across the track.
            let track = min(size.width, size.height) / 2 - Self.width / 2
            line(at: Self.assistLimit, from: track - Self.width / 2 - 2, to: track + Self.width / 2 + 1, width: 2.5, colour: .primary)
        }
    }

    private var batteryColour: Color {
        switch battery ?? 100 {
        case ...10: .red
        case ...20: .orange
        default: Color.primary.opacity(0.6)
        }
    }

    /// The blue of the route.
    private static let blue = Color(red: 0.13, green: 0.47, blue: 1)
}

/// An arc of the dial; angles in degrees, 0 at the right, growing clockwise on screen.
private struct DialArc: Shape {
    var start: Double
    var end: Double
    var inset: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { (start, end) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - inset,
                    startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        return path
    }
}

/// The assistance as CarPlay shows the drive mode: every mode in a row, the current one lit; a tap chooses one. The
/// names as large as the width allows, shortened on a narrow screen.
struct StreetnavAssistModes: View {
    let level: Int?
    let choose: (Int) -> Void

    private static let modes: [(level: Int, name: String, short: String)] = [
        (0, "Off", "Off"), (1, "Éco", "Éco"), (2, "Normal", "Norm."), (3, "Sport", "Sport"), (4, "Turbo", "Turbo"),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(size: 13, padding: 7, short: false)
            row(size: 12, padding: 5, short: false)
            row(size: 12, padding: 4, short: true)
            row(size: 11, padding: 3, short: true)
        }
        .animation(.snappy, value: level)
    }

    private func row(size: CGFloat, padding: CGFloat, short: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.modes, id: \.level) { mode in
                let current = mode.level == level
                if mode.level > 0 { Spacer(minLength: 2) }
                Button { choose(mode.level) } label: {
                    Text(verbatim: short ? mode.short : mode.name)
                        .font(.system(size: size, weight: current ? .bold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(current ? Color.primary : Color.secondary)
                        .padding(.horizontal, padding)
                        .frame(height: 30)
                        .background {
                            if current { Capsule().fill(Color.primary.opacity(0.14)) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Assistance \(StreetnavBikeLabels.assistName(mode.level))")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
