import CoreLocation
import SwiftUI

/// Where the panel's rides go: every ride, or one of them.
enum StreetnavRidesRoute: Hashable {
    case all
    case ride(StreetnavRide)
}

private let french = Locale(identifier: "fr_FR")

/// Kilometres as Maps shows them: a decimal under 100, none above.
private func kilometers(_ km: Double) -> String {
    km.formatted(.number.precision(.fractionLength(km < 100 ? 1 : 0)).locale(french))
}

/// The first letter only in capitals: « Samedi 31 octobre 2026 à 09:41 », not every word.
private func sentence(_ text: String) -> String {
    text.prefix(1).uppercased(with: french) + text.dropFirst()
}

/// « 41 min », « 1 h 05 ».
private func duration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
}

/// The streets newly ridden, and the ones ridden before, as on the map.
private enum StreetnavRideColors {
    static let new = Color.green
    static let known = Color(red: 0.16, green: 0.62, blue: 0.56)
}

// MARK: - Every ride

/// Every bike ride, newest first, by month; a hundred more as the end of the list comes into view.
struct StreetnavRidesPage: View {
    @ObservedObject private var store = StreetnavRidesStore.shared

    private var months: [(title: String, rides: [StreetnavRide])] {
        var result: [(title: String, rides: [StreetnavRide])] = []
        for ride in store.rides {
            let title = sentence(ride.startedAt.formatted(.dateTime.month(.wide).year().locale(french)))
            if result.last?.title == title { result[result.count - 1].rides.append(ride) } else { result.append((title, [ride])) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                if store.rides.isEmpty {
                    if store.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ContentUnavailableView("Aucune sortie", systemImage: "bicycle",
                                               description: Text(store.isOffline ? "Serveur injoignable." : "Aucune sortie à vélo sur le serveur."))
                    }
                }
                ForEach(months, id: \.title) { month in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(month.title)
                            .font(.headline)
                            .padding(.leading, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(month.rides.enumerated()), id: \.element.id) { index, ride in
                                if index > 0 { Rectangle().fill(Color(.separator)).frame(height: 1 / 3).padding(.leading, 72) }
                                NavigationLink(value: StreetnavRidesRoute.ride(ride)) {
                                    StreetnavRideRow(ride: ride)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if ride.id == store.rides.last?.id { Task { await store.loadMore() } }
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                }
                if store.isLoading, store.rides.isEmpty == false {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if store.isOffline, store.rides.isEmpty == false {
                    Label("Serveur injoignable : sorties de la dernière connexion.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Sorties")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
    }
}

/// A ride in a list: its name, its day and hour, its distance and time.
struct StreetnavRideRow: View {
    let ride: StreetnavRide

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.outdoor.cycle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(ride.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let meters = ride.distanceM {
                    Text("\(kilometers(meters / 1000)) km")
                        .font(.headline)
                }
                if let seconds = ride.durationS, seconds > 0 {
                    Text(duration(seconds))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        ride.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(french)) + " · "
            + ride.startedAt.formatted(.dateTime.hour().minute().locale(french))
    }
}

// MARK: - One ride

/// One ride: its streets on a small map, the new ones in green, its figures, then each street in the order it rode them;
/// a tap on a street shows it on the map.
struct StreetnavRidePage: View {
    let ride: StreetnavRide
    @State private var streets: StreetnavRideStreets?
    @State private var detail: StreetnavRideDetail?
    @State private var failed = false
    @State private var selected: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id("map")
                    figures
                    streetList
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
            }
            // A street chosen in the list: back up to the map, where it shows.
            .onChange(of: selected) { _, street in
                if street != nil { withAnimation(.snappy) { proxy.scrollTo("map", anchor: .top) } }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(ride.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        failed = false
        async let streetsCall = StreetnavRidesStore.streets(of: ride)
        async let detailCall = StreetnavRidesStore.detail(of: ride)
        do {
            streets = try await streetsCall
        } catch {
            failed = true
        }
        detail = try? await detailCall
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            StreetnavRideMap(track: detail?.track?.lines ?? [], streets: streets?.streets ?? [], selected: selected)
                .frame(height: 280)
                .overlay {
                    if streets == nil, failed == false { ProgressView() }
                }
            HStack(spacing: 16) {
                legend("Nouvelles", StreetnavRideColors.new)
                legend("Déjà parcourues", StreetnavRideColors.known)
                Spacer()
            }
            Text(sentence(ride.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(french))))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 18, height: 5)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var figures: some View {
        let summary = streets?.summary
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .leading, spacing: 16) {
            StreetnavStat(label: "Distance", value: ride.distanceM.map { kilometers($0 / 1000) } ?? "–", unit: "km")
            StreetnavStat(label: "Durée", value: ride.durationS.map(duration) ?? "–")
            StreetnavStat(label: "Nouvelles", value: summary.map { kilometers($0.newKm) } ?? "–", unit: "km")
            StreetnavStat(label: "Rues", value: summary.map { "\($0.streets)" } ?? "–")
            StreetnavStat(label: "Dénivelé", value: ride.elevationGainM.map { "\(Int($0.rounded()))" } ?? "–", unit: "m")
            if let heartRate = ride.avgHr, heartRate > 0 {
                StreetnavStat(label: "FC moyenne", value: "\(Int(heartRate.rounded()))", unit: "bpm")
            } else {
                StreetnavStat(label: "Énergie", value: ride.calories.map { "\(Int($0.rounded()))" } ?? "–", unit: "kcal")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    @ViewBuilder
    private var streetList: some View {
        if failed {
            Label("Serveur injoignable : rues indisponibles.", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        } else if let streets, streets.summary.troncons == 0 {
            Label("Aucune rue mesurée : sortie hors de Paris et de la petite couronne, ou pas encore mesurée.",
                  systemImage: "map")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        } else if let streets {
            let list = streets.streets
            VStack(alignment: .leading, spacing: 8) {
                Text("\(list.count) rues, dans l'ordre")
                    .font(.headline)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, street in
                        if index > 0 { Rectangle().fill(Color(.separator)).frame(height: 1 / 3).padding(.leading, 44) }
                        Button {
                            withAnimation(.snappy) { selected = selected == street.id ? nil : street.id }
                        } label: {
                            StreetnavRideStreetRow(street: street, selected: selected == street.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
        }
    }
}

/// A street of the ride: new or ridden before, its length ridden, whether all along, and how often it has been ridden.
private struct StreetnavRideStreetRow: View {
    let street: StreetnavRideStreets.Street
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(street.isNew ? StreetnavRideColors.new : StreetnavRideColors.known)
                .frame(width: 5, height: 28)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(street.name ?? "Sans nom")
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(street.name == nil ? .secondary : .primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if street.isNew {
                Text("Nouvelle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(StreetnavRideColors.new))
            } else if street.passages > 0 {
                Text("\(street.passages)×")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let length = street.meters >= 1000 ? "\(kilometers(street.meters / 1000)) km" : "\(Int(street.meters.rounded())) m"
        return "\(length) · \(street.complete ? "en entier" : "en partie")"
    }
}

/// The ride drawn on its own: its track thin and grey, its streets over it, the new ones in green, the one chosen in the
/// list on top; north up, fitted to the frame.
struct StreetnavRideMap: View {
    let track: [[CLLocationCoordinate2D]]
    let streets: [StreetnavRideStreets.Street]
    let selected: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let all = (track.isEmpty ? streets.flatMap(\.lines) : track).flatMap { $0 }
            guard let projection = Projection(points: all, size: size, inset: 14) else { return }
            func path(_ lines: [[CLLocationCoordinate2D]]) -> Path {
                var path = Path()
                for line in lines where line.count > 1 {
                    path.move(to: projection.point(line[0]))
                    for coordinate in line.dropFirst() { path.addLine(to: projection.point(coordinate)) }
                }
                return path
            }
            let round = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            context.stroke(path(track), with: .color(.secondary.opacity(0.5)), style: round)
            for street in streets where street.isNew == false {
                context.stroke(path(street.lines), with: .color(StreetnavRideColors.known), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
            for street in streets where street.isNew {
                context.stroke(path(street.lines), with: .color(StreetnavRideColors.new), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            if let selected, let street = streets.first(where: { $0.id == selected }) {
                let highlight: Color = colorScheme == .dark ? .white : .black
                context.stroke(path(street.lines), with: .color(highlight), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Carte des rues de la sortie")
    }

    /// Longitude shrunk by the cosine of the middle latitude, so that a street keeps its shape; fitted and centred.
    private struct Projection {
        let minX: Double, maxY: Double, scale: Double, offset: CGPoint, shrink: Double

        init?(points: [CLLocationCoordinate2D], size: CGSize, inset: CGFloat) {
            guard let first = points.first else { return nil }
            var (minLon, maxLon, minLat, maxLat) = (first.longitude, first.longitude, first.latitude, first.latitude)
            for point in points {
                minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
                minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            }
            shrink = cos((minLat + maxLat) / 2 * .pi / 180)
            let width = max((maxLon - minLon) * shrink, 1e-6), height = max(maxLat - minLat, 1e-6)
            let room = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
            scale = min(room.width / width, room.height / height)
            minX = minLon * shrink
            maxY = maxLat
            offset = CGPoint(x: inset + (room.width - width * scale) / 2, y: inset + (room.height - height * scale) / 2)
        }

        func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: offset.x + (coordinate.longitude * shrink - minX) * scale, y: offset.y + (maxY - coordinate.latitude) * scale)
        }
    }
}
