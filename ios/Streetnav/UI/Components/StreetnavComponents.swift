import SwiftUI

struct StreetnavSearchCapsule: View {
    var text = "Ou explorer ?"
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                Text(text)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rechercher une destination ou un quartier")
    }
}

struct StreetnavFloatingControl: View {
    let symbolName: String
    let label: String
    var isSelected = false
    var isDisabled = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(width: 48, height: 48)
                .background(isSelected ? Color.accentColor : Color.clear, in: Circle())
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.13), radius: 10, y: 4)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(label)
    }
}

struct StreetnavPrimaryAction: View {
    let title: String
    var symbolName: String = "arrow.right"
    var isLoading = false
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: symbolName)
                        .font(.headline)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
            .background(isDisabled ? Color.secondary.opacity(0.25) : Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(isDisabled ? Color.secondary : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(title)
    }
}

struct StreetnavStatusPill: View {
    let title: String
    let symbolName: String
    var tint: Color = .green
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct StreetnavBottomCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(.secondary.opacity(0.35))
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            content
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

struct StreetnavRouteMetric: View {
    let title: String
    let value: String
    var symbolName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let symbolName {
                Image(systemName: symbolName)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StreetnavRouteAlternativeCard: View {
    let alternative: RouteAlternative
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(alternative.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(alternative.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(alternative.durationMinutes) min", systemImage: "clock")
                    Label(String(format: "%.1f km", alternative.newRoadKilometers), systemImage: "sparkle")
                }
                .font(.caption.weight(.medium))
            }
            .padding(12)
            .frame(width: 210, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Alternative \(alternative.title)")
    }
}

struct StreetnavManeuverCard: View {
    let instruction: NavigationInstruction
    var gpsQuality: GPSQuality = .precise

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: instruction.symbolName)
                .font(.system(size: 34, weight: .bold))
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(gpsQuality == .weak ? "Signal GPS faible" : instruction.distanceText)
                    .font(.title3.weight(.semibold))
                Text(instruction.maneuver)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(instruction.streetName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(instruction.spokenLabel)
    }
}

struct StreetnavRideProgressBar: View {
    let progress: RideProgress

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: progress.routeProgress)
                .tint(.mint)
                .accessibilityLabel("Progression de l'itineraire")
            HStack {
                StreetnavRouteMetric(title: "restantes", value: "\(progress.remainingMinutes) min", symbolName: "clock")
                StreetnavRouteMetric(title: "a rouler", value: String(format: "%.1f km", progress.remainingKilometers), symbolName: "point.topleft.down.curvedto.point.bottomright.up")
                StreetnavRouteMetric(title: "decouverts", value: "+\(progress.completedNewRoadMeters) m", symbolName: "checkmark.seal")
            }
        }
        .padding(14)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StreetnavDeviceStatusRow: View {
    let title: String
    let subtitle: String
    let state: DeviceConnectionState
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .foregroundStyle(color(for: state))
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    private func color(for state: DeviceConnectionState) -> Color {
        switch state {
        case .ready: .green
        case .connecting: .orange
        case .unavailable: .secondary
        case .actionRequired: .red
        }
    }
}

struct StreetnavExplorationBadge: View {
    let area: ExplorationArea

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: area.completion)
                    .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(area.completion * 100))")
                    .font(.caption.weight(.bold))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(area.name)
                    .font(.headline)
                Text(area.remainingKilometers > 0 ? String(format: "%.1f km a decouvrir", area.remainingKilometers) : "Quartier complet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StreetnavMapLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legend("Parcouru", color: .blue, dash: false)
            legend("A decouvrir", color: .red, dash: true)
            legend("Itineraire", color: .mint, dash: false)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private func legend(_ title: String, color: Color, dash: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: dash ? 16 : 22, height: 4)
                .overlay {
                    if dash { Capsule().stroke(.background, style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
                }
            Text(title)
        }
    }
}

struct StreetnavCompletionToast: View {
    var meters: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nouvelle rue parcourue")
                    .font(.headline)
                Text("+\(meters) m decouverts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
