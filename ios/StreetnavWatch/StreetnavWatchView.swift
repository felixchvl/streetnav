import SwiftUI

/// Before the ride, one button; during it, the time, the heart rate, the distance and the bike as the iPhone reports
/// it, and the end of the ride, confirmed.
struct StreetnavWatchView: View {
    @ObservedObject private var ride = StreetnavWatchRide.shared
    @State private var confirmsEnd = false

    var body: some View {
        switch ride.phase {
        case .idle:
            start
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                start
            }
        case .starting, .riding, .ending:
            riding
        }
    }

    private var start: some View {
        VStack(spacing: 8) {
            Button {
                Task { await ride.start() }
            } label: {
                Image(systemName: "bicycle")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 100, height: 100)
                    .background(Circle().fill(.green))
            }
            // A bordered button takes the whole width on the Watch.
            .buttonStyle(.plain)
            .accessibilityLabel("Partir à vélo")
            Text("Partir à vélo")
                .font(.headline)
            Text("Ou le bouton Action")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var riding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.yellow)
                }
                Label(ride.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "— bpm", systemImage: "heart.fill")
                    .symbolRenderingMode(.multicolor)
                Label(Measurement(value: ride.distanceMeters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road)), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Label(ride.bike?.label ?? "iPhone : en attente…", systemImage: ride.bike == .unlocked ? "lock.open.fill" : "iphone")
                    .font(.footnote)
                    .foregroundStyle(ride.bike == .unlocked ? .green : .secondary)
                Button(role: .destructive) {
                    confirmsEnd = true
                } label: {
                    Label("Terminer", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 6)
                .disabled(ride.phase != .riding)
            }
        }
        .confirmationDialog("Terminer la sortie ?", isPresented: $confirmsEnd) {
            Button("Terminer et enregistrer", role: .destructive) { ride.end() }
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = ride.startDate else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
