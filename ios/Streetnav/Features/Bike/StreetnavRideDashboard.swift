import CoreLocation
import SwiftUI

/// The navigation's trip card, laid out as the VanMoof app's ride dashboard: the bike above (its name, a green dot while
/// connected, its battery; the unlock button instead while it is locked), then the speed large under a dotted arc that
/// fills as it rises and turns red past 25 km/h, between the time and the distance left. The speed is the bike's once
/// its unit is known, the GPS's otherwise.
struct StreetnavRideDashboard: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    @ObservedObject private var account = StreetnavVanMoofAccount.shared
    /// The rider's position from the guidance, for its speed.
    let location: CLLocation?
    let timeLeft: (value: String, unit: String)
    let arrival: String
    let distanceLeft: (value: String, unit: String)
    @State private var isUnlocking = false
    @State private var unlockFailed = false

    var body: some View {
        VStack(spacing: 10) {
            if bike.state == .ready {
                if bike.isLocked == true {
                    unlockButton
                        .transition(.blurReplace)
                } else {
                    header
                        .transition(.blurReplace)
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                side(timeLeft.value, unit: timeLeft.unit, label: "arrivée \(arrival)")
                StreetnavSpeedGauge(speed: speed)
                    .frame(width: 172)
                side(distanceLeft.value, unit: distanceLeft.unit, label: "restants")
            }
        }
        .animation(.snappy, value: bike.isLocked)
        .animation(.snappy, value: bike.state == .ready)
        .onChange(of: location) { _, location in
            if bike.state == .ready, let location, location.speed >= 0 { bike.noteGPS(speedKmh: location.speed * 3.6) }
        }
        // While the bike is connected: its speed twice a second, its battery and lock every ten seconds.
        .task(id: bike.state == .ready) {
            var tick = 0
            while Task.isCancelled == false, bike.state == .ready {
                bike.refreshSpeed()
                if tick % 20 == 0 { bike.refreshStatus() }
                tick += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bicycle")
                .font(.system(size: 15, weight: .semibold))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .offset(x: -3, y: -4)
                }
            Text(account.bike?.name ?? "VanMoof")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            StreetnavBikeBattery(percent: bike.battery)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    private var unlockButton: some View {
        Button {
            isUnlocking = true
            unlockFailed = false
            Task {
                unlockFailed = await bike.unlock() == false
                isUnlocking = false
            }
        } label: {
            HStack(spacing: 8) {
                if isUnlocking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "lock.open.fill")
                }
                Text(unlockFailed ? "Réessayer de déverrouiller" : "Déverrouiller le vélo")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(isUnlocking)
    }

    /// A value with its unit set small after it, and what it is beneath, as the VanMoof app's « 0.3 km / trip ».
    private func side(_ value: String, unit: String, label: String) -> some View {
        VStack(spacing: 1) {
            (Text(value).font(.system(size: 26, weight: .bold))
                + Text(verbatim: " \(unit)").font(.system(size: 16, weight: .semibold)))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    private var speed: Double? {
        if bike.state == .ready, let kmh = bike.speedKmh { return kmh }
        guard let location, location.speed >= 0 else { return nil }
        return location.speed * 3.6
    }
}

/// The speed, large, under an arc of dots from 0 to 32 km/h: solid up to the speed, the dots past 25 km/h (where the
/// motor stops helping) in red, as on the VanMoof dashboard.
struct StreetnavSpeedGauge: View {
    let speed: Double?

    private static let range = 32.0
    private static let limit = 25.0
    private static let arcHeight: CGFloat = 32

    var body: some View {
        let reached = min(1, max(0, (speed ?? 0) / Self.range))
        let limit = Self.limit / Self.range
        VStack(spacing: -14) {
            ZStack {
                Canvas { context, size in
                    let arc = GaugeArc(from: 0, to: 1)
                    let count = 27
                    for index in 0..<count {
                        let t = Double(index) / Double(count - 1)
                        let point = arc.point(at: t, in: CGRect(origin: .zero, size: size))
                        let dot = Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2))
                        context.fill(dot, with: .color(t > limit + 0.001 ? Color.red.opacity(0.8) : Color.secondary.opacity(0.45)))
                    }
                }
                GaugeArc(from: 0, to: min(reached, limit))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .opacity(reached > 0 ? 1 : 0)
                GaugeArc(from: limit, to: max(reached, limit))
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .opacity(reached > limit ? 1 : 0)
            }
            .frame(height: Self.arcHeight)
            VStack(spacing: -8) {
                Text(speed.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 64, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.45), value: reached)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vitesse \(speed.map { "\(Int($0.rounded())) km/h" } ?? "inconnue")")
    }
}

/// A part of the gauge's arc, `from` and `to` between 0 (its left end) and 1 (its right end): a shallow arc of a circle,
/// its ends low at the sides, its middle at the top, inset for the line's width.
private struct GaugeArc: Shape {
    var from: Double
    var to: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set { (from, to) = (newValue.first, newValue.second) }
    }

    private static let inset: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        let (centre, radius, half) = Self.circle(in: rect)
        path.addArc(center: centre, radius: radius, startAngle: .degrees(270 - half + 2 * half * from),
                    endAngle: .degrees(270 - half + 2 * half * to), clockwise: false)
        return path
    }

    func point(at t: Double, in rect: CGRect) -> CGPoint {
        let (centre, radius, half) = Self.circle(in: rect)
        let angle = (270 - half + 2 * half * t) * .pi / 180
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }

    /// The circle through the arc's two low ends and its top, and half the angle the arc spans, in degrees.
    private static func circle(in rect: CGRect) -> (CGPoint, Double, Double) {
        let chord = Double(rect.width - 2 * inset)
        let sag = Double(rect.height - 2 * inset)
        let radius = (chord * chord / 4 + sag * sag) / (2 * sag)
        let half = asin(chord / 2 / radius) * 180 / .pi
        return (CGPoint(x: rect.midX, y: rect.minY + inset + radius), radius, half)
    }
}
