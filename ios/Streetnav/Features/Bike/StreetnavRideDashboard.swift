import CoreLocation
import SwiftUI

/// The navigation's trip card: the speed on a gauge in the middle, as the VanMoof app's ride dashboard leads with it,
/// the time left and the arrival on its left, the distance left and the bike's battery on its right. The speed is the
/// bike's once its unit is known, the GPS's otherwise; the battery only while the bike is connected.
struct StreetnavRideDashboard: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    /// The rider's position from the guidance, for its speed.
    let location: CLLocation?
    let timeLeft: (value: String, unit: String)
    let arrival: String
    let distanceLeft: (value: String, unit: String)

    /// The top of the gauge, and where the motor stops helping.
    private static let top = 30.0
    private static let limit = 25.0

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 12) {
                metric(timeLeft.value, unit: timeLeft.unit, label: "restantes")
                metric(arrival, label: "arrivée")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Gauge(value: min(speed ?? 0, Self.top), in: 0...Self.top) {
                Text("km/h")
            } currentValueLabel: {
                Text(speed.map { "\(Int($0.rounded()))" } ?? "—")
            }
            .gaugeStyle(StreetnavSpeedGaugeStyle(limit: Self.limit / Self.top))
            .frame(width: 128, height: 128)
            VStack(alignment: .trailing, spacing: 12) {
                metric(distanceLeft.value, unit: distanceLeft.unit, label: "restants", alignment: .trailing)
                if bike.state == .ready {
                    metric(bike.battery.map { "\($0)" } ?? "—", unit: "%", label: "batterie", alignment: .trailing, tint: batteryTint)
                        .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .animation(.snappy, value: bike.state == .ready)
        .onChange(of: location) { _, location in
            if bike.state == .ready, let location, location.speed >= 0 { bike.noteGPS(speedKmh: location.speed * 3.6) }
        }
        // While the bike is connected: its speed twice a second, its battery every ten seconds.
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

    /// A value with its unit, and what it is beneath.
    private func metric(_ value: String, unit: String? = nil, label: String, alignment: HorizontalAlignment = .leading,
                        tint: Color = .primary) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text("\(Text(value).font(.title.weight(.semibold)))\(Text(unit.map { " \($0)" } ?? "").font(.title3.weight(.semibold)))")
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var batteryTint: Color {
        switch bike.battery ?? 100 {
        case ...10: .red
        case ...20: .orange
        default: .primary
        }
    }

    private var speed: Double? {
        if bike.state == .ready, let kmh = bike.speedKmh { return kmh }
        guard let location, location.speed >= 0 else { return nil }
        return location.speed * 3.6
    }
}

/// A gauge drawn as an open ring, gap at the bottom, filled up to its value as Apple's capacity gauges are: in the blue
/// of the route, turning orange then red past `limit` (a share of the range); its current value large in the middle,
/// its label beneath.
struct StreetnavSpeedGaugeStyle: GaugeStyle {
    var limit: Double

    private static let start = 135.0
    private static let sweep = 270.0
    private static let width: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RingArc(from: 0, to: 1)
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: Self.width, lineCap: .round))
            RingArc(from: 0, to: configuration.value)
                .stroke(AngularGradient(stops: stops, center: .center, startAngle: .degrees(Self.start),
                                        endAngle: .degrees(Self.start + Self.sweep)),
                        style: StrokeStyle(lineWidth: Self.width, lineCap: .round))
                .opacity(configuration.value > 0 ? 1 : 0)
            VStack(spacing: -6) {
                configuration.currentValueLabel
                    .font(.system(size: 46, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                configuration.label
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .offset(y: 2)
        }
        .animation(.easeOut(duration: 0.45), value: configuration.value)
    }

    private var stops: [Gradient.Stop] {
        let blue = Color(red: 0.13, green: 0.47, blue: 1)
        return [.init(color: blue.opacity(0.7), location: 0), .init(color: blue, location: limit - 0.04),
                .init(color: .orange, location: limit + 0.02), .init(color: .red, location: 1)]
    }

    /// A part of the ring, `from` and `to` between 0 (its start, bottom left) and 1 (its end, bottom right).
    private struct RingArc: Shape {
        var from: Double
        var to: Double

        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(from, to) }
            set { (from, to) = (newValue.first, newValue.second) }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard to > from else { return path }
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - width / 2,
                        startAngle: .degrees(start + sweep * from), endAngle: .degrees(start + sweep * to), clockwise: false)
            return path
        }
    }
}
