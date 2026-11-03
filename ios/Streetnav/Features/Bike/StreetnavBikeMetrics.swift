import CoreLocation
import SwiftUI

/// A number and what it counts beneath it: the one look of every value in the navigation, as Maps lays out its trip
/// and the VanMoof app its rides. Larger for the one value that leads.
struct StreetnavMetric: View {
    let value: String
    let label: String
    var size: CGFloat = 27
    var tint: Color = .primary

    var body: some View {
        // A large number's line leaves room enough above its label.
        VStack(spacing: size > 40 ? -8 : 0) {
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The speed of the bike, leading the navigation's trip card while the bike is connected; in its place, while the bike
/// is locked, the button that unlocks it. The bike's speed once its unit is known, the GPS's until then.
struct StreetnavBikeSpeed: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    /// The rider's position from the guidance, for its speed.
    let location: CLLocation?
    @State private var isUnlocking = false
    @State private var unlockFailed = false

    var body: some View {
        if bike.state == .ready {
            Group {
                if bike.isLocked == true {
                    unlockButton
                } else {
                    StreetnavMetric(value: speed.map { "\(Int($0.rounded()))" } ?? "—", label: "km/h", size: 56)
                }
            }
            .transition(.blurReplace)
            .animation(.snappy, value: bike.isLocked)
            .animation(.snappy, value: speed.map { Int($0.rounded()) })
            .onChange(of: location) { _, location in
                if let location, location.speed >= 0 { bike.noteGPS(speedKmh: location.speed * 3.6) }
            }
            // The speed twice a second, the battery and the lock every ten seconds.
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
        .controlSize(.large)
        .disabled(isUnlocking)
    }

    private var speed: Double? {
        if let kmh = bike.speedKmh { return kmh }
        guard let location, location.speed >= 0 else { return nil }
        return location.speed * 3.6
    }
}

/// The bike's battery among the trip's values, while the bike is connected: amber when low, red when nearly empty.
struct StreetnavBikeBatteryMetric: View {
    @ObservedObject private var bike = StreetnavVanMoofBike.shared

    var body: some View {
        if bike.state == .ready {
            StreetnavMetric(value: bike.battery.map { "\($0) %" } ?? "—", label: "batterie", tint: tint)
        }
    }

    private var tint: Color {
        switch bike.battery ?? 100 {
        case ...10: .red
        case ...20: .orange
        default: .primary
        }
    }
}
