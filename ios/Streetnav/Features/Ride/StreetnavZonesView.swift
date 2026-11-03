import SwiftUI

typealias StreetnavZone = StreetnavRideHistory.Stats.Zone

/// Paris or a ring of communes, a department: the arrondissements or communes it holds and their streets together.
struct StreetnavZoneGroup: Identifiable, Hashable {
    enum Kind: Hashable {
        case department(String)
        case ring(Int)
    }

    let kind: Kind
    let title: String
    let detail: String
    let zones: [StreetnavZone]

    var id: Kind { kind }
    var riddenKm: Double { zones.reduce(0) { $0 + $1.riddenKm } }
    var totalKm: Double { zones.reduce(0) { $0 + $1.totalKm } }
    var share: Double { totalKm > 0 ? riddenKm / totalKm : 0 }

    static func == (lhs: StreetnavZoneGroup, rhs: StreetnavZoneGroup) -> Bool { lhs.kind == rhs.kind }
    func hash(into hasher: inout Hasher) { hasher.combine(kind) }

    /// Paris, then the communes along its edge, the ring after, and so on to the far end of the 92, 93 and 94.
    static func rings(_ zones: [StreetnavZone]) -> [StreetnavZoneGroup] {
        let byRing = Dictionary(grouping: zones.filter { $0.ring != nil }) { $0.ring ?? 0 }
        return byRing.keys.sorted().map { ring in
            let members = byRing[ring] ?? []
            let title: String
            let detail: String
            switch ring {
            case 0: (title, detail) = ("Paris", "\(members.count) arrondissements")
            case 1: (title, detail) = ("1re couronne", "\(members.count) communes limitrophes")
            default: (title, detail) = ("\(ring)e couronne", "\(members.count) communes")
            }
            return StreetnavZoneGroup(kind: .ring(ring), title: title, detail: detail, zones: members)
        }
    }

    static func departments(_ zones: [StreetnavZone]) -> [StreetnavZoneGroup] {
        let names = ["75": "Paris", "92": "Hauts-de-Seine", "93": "Seine-Saint-Denis", "94": "Val-de-Marne"]
        return Dictionary(grouping: zones, by: \.department).sorted { $0.key < $1.key }.map { department, members in
            StreetnavZoneGroup(kind: .department(department), title: "\(names[department] ?? department) (\(department))",
                               detail: department == "75" ? "\(members.count) arrondissements" : "\(members.count) communes",
                               zones: members)
        }
    }

    /// « Paris 1er Arrondissement » from API Géo, « 1er arrondissement » here.
    static func name(_ zone: StreetnavZone) -> String {
        guard zone.department == "75" else { return zone.name }
        return zone.name.replacingOccurrences(of: "Paris ", with: "").replacingOccurrences(of: "Arrondissement", with: "arrondissement")
    }
}

/// A map of zones, each filled darker the more of its streets were ridden, in the green of the streets ridden; the
/// others, when `highlighted` leaves them out, in grey. Fitted to the zones highlighted (all of them by default).
struct StreetnavZoneMap: View {
    let shapes: [String: [[CGPoint]]]
    let zones: [StreetnavZone]
    var highlighted: Set<String>?
    var borders = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let fitted = zones.filter { highlighted?.contains($0.code) ?? true }.compactMap { shapes[$0.code] }.flatMap { $0 }.flatMap { $0 }
            guard let projection = Projection(points: fitted, size: size) else { return }
            for zone in zones {
                guard let rings = shapes[zone.code] else { continue }
                var path = Path()
                for ring in rings {
                    path.addLines(ring.map(projection.point))
                    path.closeSubpath()
                }
                let inGroup = highlighted?.contains(zone.code) ?? true
                let fill = inGroup ? Self.fill(share: zone.totalKm > 0 ? zone.riddenKm / zone.totalKm : 0, dark: colorScheme == .dark)
                    : Color(.quaternarySystemFill)
                context.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                if borders {
                    context.stroke(path, with: .color(Color(.systemBackground).opacity(0.9)), lineWidth: 0.6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// From a pale green for nothing ridden to a deep one for every street, the low shares spread out (most zones
    /// outside Paris are under a fifth).
    static func fill(share: Double, dark: Bool) -> Color {
        let t = pow(min(1, max(0, share)), 0.6)
        let (from, to): ((Double, Double, Double), (Double, Double, Double)) = dark
            ? ((0.16, 0.22, 0.18), (0.24, 0.90, 0.42))
            : ((0.89, 0.95, 0.90), (0.05, 0.44, 0.18))
        return Color(red: from.0 + (to.0 - from.0) * t, green: from.1 + (to.1 - from.1) * t, blue: from.2 + (to.2 - from.2) * t)
    }

    /// Longitude and latitude to points, the longitude shortened by the cosine of the latitude, fitted in `size`.
    private struct Projection {
        let origin: CGPoint
        let scale: Double
        let offset: CGSize
        let shrink: Double

        init?(points: [CGPoint], size: CGSize) {
            guard let first = points.first, size.width > 0, size.height > 0 else { return nil }
            var low = first
            var high = first
            for point in points {
                low = CGPoint(x: min(low.x, point.x), y: min(low.y, point.y))
                high = CGPoint(x: max(high.x, point.x), y: max(high.y, point.y))
            }
            shrink = cos((low.y + high.y) / 2 * .pi / 180)
            let width = max(1e-9, (high.x - low.x) * shrink)
            let height = max(1e-9, high.y - low.y)
            scale = min(size.width / width, size.height / height)
            origin = CGPoint(x: low.x, y: high.y)
            offset = CGSize(width: (size.width - width * scale) / 2, height: (size.height - height * scale) / 2)
        }

        func point(_ lonLat: CGPoint) -> CGPoint {
            CGPoint(x: offset.width + (lonLat.x - origin.x) * shrink * scale, y: offset.height + (origin.y - lonLat.y) * scale)
        }
    }
}

/// The legend of the zone maps: pale for no street ridden, deep for all of them.
struct StreetnavZoneLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "0 %")
            LinearGradient(colors: stride(from: 0, through: 1, by: 0.25).map { StreetnavZoneMap.fill(share: $0, dark: colorScheme == .dark) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
            Text(verbatim: "100 %")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plus une zone est foncée, plus ses rues ont été parcourues")
    }
}

/// A department or a ring, on a page of its own: its map, its share of streets ridden, then each of its arrondissements
/// or communes from the most ridden.
struct StreetnavZonePage: View {
    let group: StreetnavZoneGroup
    /// Every zone, for a ring drawn among the others.
    let all: [StreetnavZone]
    let shapes: [String: [[CGPoint]]]

    private static let french = Locale(identifier: "fr_FR")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    if shapes.isEmpty == false {
                        StreetnavZoneMap(shapes: shapes, zones: isRing ? all : group.zones,
                                         highlighted: isRing ? Set(group.zones.map(\.code)) : nil)
                            .frame(height: 300)
                        StreetnavZoneLegend()
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(percent(group.share))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("des rues · \(kilometers(group.riddenKm)) km sur \(kilometers(group.totalKm))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                VStack(spacing: 0) {
                    let sorted = group.zones.sorted { share($0) > share($1) }
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, zone in
                        if index > 0 {
                            Rectangle().fill(Color(.separator)).frame(height: 1 / 3).padding(.leading, 16)
                        }
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(StreetnavZoneMap.fill(share: share(zone), dark: false))
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(StreetnavZoneGroup.name(zone))
                                Text(zone.totalKm > 0 ? "\(kilometers(zone.riddenKm)) km sur \(kilometers(zone.totalKm))" : "rues pas encore chargées")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(zone.totalKm > 0 ? percent(share(zone)) : "–")
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isRing: Bool {
        if case .ring = group.kind { return true }
        return false
    }

    private func share(_ zone: StreetnavZone) -> Double { zone.totalKm > 0 ? zone.riddenKm / zone.totalKm : 0 }

    private func percent(_ share: Double) -> String {
        "\((share * 100).formatted(.number.precision(.fractionLength(0)).locale(Self.french))) %"
    }

    private func kilometers(_ km: Double) -> String {
        km.formatted(.number.precision(.fractionLength(km < 100 ? 1 : 0)).locale(Self.french))
    }
}
