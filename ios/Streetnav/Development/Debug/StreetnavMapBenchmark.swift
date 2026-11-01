#if DEBUG
import MapboxMaps
import MapKit
import QuartzCore
import SwiftUI

/// Development tool: draws the same heavy data (every street of Paris, or every recorded track) with MapKit and with
/// Mapbox, flies the same camera tour and measures load time, frame pacing and memory.
///
/// Opened with the launch arguments `-benchEngine mapbox|mapkit|mapkitSwiftUI -benchData streets|tracks|both`. The data
/// files (`paris-streets.geojson`, `tracks.geojson`) are read from the app's Documents folder and never ship with the
/// app; results go to `Documents/bench-<engine>-<data>.json` and to the console.
enum StreetnavMapBenchmark {
    enum Engine: String { case mapbox, mapkit, mapkitSwiftUI }
    enum Dataset: String { case streets, tracks, both }

    struct Line: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let state: String
    }

    static var request: (engine: Engine, data: Dataset)? {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let engine = value("-benchEngine").flatMap(Engine.init) else { return nil }
        return (engine, value("-benchData").flatMap(Dataset.init) ?? .both)
    }

    static func files(for data: Dataset) -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let streets = documents.appending(path: "paris-streets.geojson"), tracks = documents.appending(path: "tracks.geojson")
        switch data {
        case .streets: return [streets]
        case .tracks: return [tracks]
        case .both: return [streets, tracks]
        }
    }

    /// Reads the LineString features of a GeoJSON file; features without a `state` property take `defaultState`.
    static func readLines(_ url: URL, defaultState: String) throws -> [Line] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let features = object?["features"] as? [[String: Any]] ?? []
        return features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any], let points = geometry["coordinates"] as? [[Double]] else { return nil }
            let state = (feature["properties"] as? [String: Any])?["state"] as? String ?? defaultState
            return Line(coordinates: points.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }, state: state)
        }
    }

    /// The same regions, in the same order, for every engine: all of Paris, then four neighbourhoods, then Paris again.
    static let tour: [(center: CLLocationCoordinate2D, span: CLLocationDistance)] = [
        (CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), 11_000),
        (CLLocationCoordinate2D(latitude: 48.8710, longitude: 2.3660), 1_500),
        (CLLocationCoordinate2D(latitude: 48.8530, longitude: 2.3690), 1_500),
        (CLLocationCoordinate2D(latitude: 48.8420, longitude: 2.3210), 3_000),
        (CLLocationCoordinate2D(latitude: 48.8860, longitude: 2.3430), 1_500),
        (CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), 11_000),
    ]
    static let stepDuration: TimeInterval = 2

    static func region(center: CLLocationCoordinate2D, span: CLLocationDistance) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
    }

    static func corners(center: CLLocationCoordinate2D, span: CLLocationDistance) -> [CLLocationCoordinate2D] {
        let dLat = span / 2 / 111_320, dLon = span / 2 / (111_320 * cos(center.latitude * .pi / 180))
        return [CLLocationCoordinate2D(latitude: center.latitude - dLat, longitude: center.longitude - dLon),
                CLLocationCoordinate2D(latitude: center.latitude + dLat, longitude: center.longitude + dLon)]
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// One measured run: file reading, time until the map shows the data, then frame pacing during the camera tour.
@MainActor
final class StreetnavBenchRun: ObservableObject {
    @Published private(set) var status = "Lecture des fichiers..."
    let engine: StreetnavMapBenchmark.Engine
    let data: StreetnavMapBenchmark.Dataset
    private var results: [String: Any] = [:]
    private var loadStart = CACurrentMediaTime()
    private var frameLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var frameIntervals: [Double] = []
    private var finished = false

    init(engine: StreetnavMapBenchmark.Engine, data: StreetnavMapBenchmark.Dataset) {
        self.engine = engine
        self.data = data
        results = ["engine": engine.rawValue, "data": data.rawValue, "memoryAtStartMB": StreetnavMapBenchmark.footprintMB()]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(240))
            self?.finish(timedOut: true)
        }
    }

    func dataRead(lines: Int, points: Int, milliseconds: Double) {
        results["lines"] = lines
        results["points"] = points
        results["readMs"] = milliseconds
        status = "\(lines) lignes, \(points) points lus en \(Int(milliseconds)) ms"
    }

    func startLoading() {
        loadStart = CACurrentMediaTime()
        status += "\nChargement dans la carte..."
    }

    func dataShown() {
        guard results["loadMs"] == nil else { return }
        results["loadMs"] = (CACurrentMediaTime() - loadStart) * 1000
        results["memoryLoadedMB"] = StreetnavMapBenchmark.footprintMB()
        status += "\nAffiché en \(Int((CACurrentMediaTime() - loadStart) * 1000)) ms, tour de caméra..."
    }

    func runTour(move: (CLLocationCoordinate2D, CLLocationDistance, TimeInterval) -> Void) async {
        frameIntervals = []
        lastFrame = 0
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        frameLink = link
        for step in StreetnavMapBenchmark.tour {
            move(step.center, step.span, StreetnavMapBenchmark.stepDuration)
            try? await Task.sleep(for: .seconds(StreetnavMapBenchmark.stepDuration + 0.3))
        }
        frameLink?.invalidate()
    }

    /// Times an update of the drawn data until the map has drawn it (`done` is called by the engine), 10 s at most.
    func measure(_ name: String, _ update: (@escaping () -> Void) -> Void) async {
        status += "\nMesure : \(name)..."
        let start = CACurrentMediaTime()
        var resumed = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = {
                guard resumed == false else { return }
                resumed = true
                continuation.resume()
            }
            update(resume)
            Task { try? await Task.sleep(for: .seconds(10)); resume() }
        }
        results[name + "Ms"] = (CACurrentMediaTime() - start) * 1000
    }

    func complete() { finish(timedOut: false) }

    @objc private func frame(_ link: CADisplayLink) {
        if lastFrame > 0 { frameIntervals.append(link.timestamp - lastFrame) }
        lastFrame = link.timestamp
    }

    private func finish(timedOut: Bool) {
        guard finished == false else { return }
        finished = true
        frameLink?.invalidate()
        let sorted = frameIntervals.sorted(), total = frameIntervals.reduce(0, +)
        results["timedOut"] = timedOut
        results["frames"] = frameIntervals.count
        results["fps"] = total > 0 ? Double(frameIntervals.count) / total : 0
        results["hitchPercent"] = frameIntervals.isEmpty ? 0 : Double(frameIntervals.filter { $0 > 0.025 }.count) / Double(frameIntervals.count) * 100
        results["p95Ms"] = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000
        results["worstMs"] = (sorted.last ?? 0) * 1000
        results["memoryAfterTourMB"] = StreetnavMapBenchmark.footprintMB()
        let json = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? json.write(to: documents.appending(path: "bench-\(engine.rawValue)-\(data.rawValue).json"))
        print("BENCH " + (String(data: json, encoding: .utf8) ?? ""))
        status = timedOut ? "Abandon après 240 s" : String(format: "Fini : %.0f i/s, %.1f %% d'à-coups, pire image %.0f ms", results["fps"] as? Double ?? 0, results["hitchPercent"] as? Double ?? 0, results["worstMs"] as? Double ?? 0)
    }
}

struct StreetnavMapBenchmarkView: View {
    @StateObject private var run: StreetnavBenchRun

    init(engine: StreetnavMapBenchmark.Engine, data: StreetnavMapBenchmark.Dataset) {
        _run = StateObject(wrappedValue: StreetnavBenchRun(engine: engine, data: data))
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch run.engine {
            case .mapbox: StreetnavBenchMapbox(run: run)
            case .mapkit: StreetnavBenchMapKit(run: run)
            case .mapkitSwiftUI: StreetnavBenchSwiftUIMap(run: run)
            }
            Text("\(run.engine.rawValue) / \(run.data.rawValue)\n\(run.status)")
                .font(.caption.monospaced())
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 60)
                .padding(.horizontal, 16)
        }
        .ignoresSafeArea()
    }
}

/// Mapbox: the GeoJSON goes straight to the engine, which tiles it on a worker thread and draws it on the GPU.
private struct StreetnavBenchMapbox: UIViewRepresentable {
    let run: StreetnavBenchRun

    final class Coordinator { var cancelables = Set<AnyCancelable>() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapView {
        let first = StreetnavMapBenchmark.tour[0]
        let mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: CameraOptions(center: first.center, zoom: 11)))
        mapView.mapboxMap.styleURI = .standard
        let coordinator = context.coordinator
        mapView.mapboxMap.onStyleLoaded.observeNext { _ in
            Task { @MainActor in
                let start = CACurrentMediaTime()
                let texts = StreetnavMapBenchmark.files(for: run.data).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                run.dataRead(lines: 0, points: 0, milliseconds: (CACurrentMediaTime() - start) * 1000)
                run.startLoading()
                for (index, text) in texts.enumerated() {
                    var source = GeoJSONSource(id: "bench-\(index)")
                    source.data = .string(text)
                    source.generateId = true
                    try? mapView.mapboxMap.addSource(source)
                    var layer = LineLayer(id: "bench-lines-\(index)", source: "bench-\(index)")
                    layer.lineColor = .expression(Exp(.switchCase) {
                        Exp(.boolean) {
                            Exp(.featureState) { "ridden" }
                            false
                        }
                        UIColor.systemGreen
                        Exp(.match) {
                            Exp(.get) { "state" }
                            "traveled"
                            UIColor.systemGray
                            UIColor.systemBlue
                        }
                    })
                    layer.lineWidth = .constant(1.5)
                    layer.slot = .middle
                    try? mapView.mapboxMap.addLayer(layer)
                }
                mapView.mapboxMap.onMapIdle.observeNext { _ in
                    Task { @MainActor in
                        run.dataShown()
                        await run.runTour { center, span, duration in
                            let camera = (try? mapView.mapboxMap.camera(for: StreetnavMapBenchmark.corners(center: center, span: span), camera: CameraOptions(), coordinatesPadding: .zero, maxZoom: nil, offset: nil)) ?? CameraOptions(center: center)
                            mapView.camera.ease(to: camera, duration: duration, curve: .easeInOut)
                        }
                        // One street, then a tenth of them, become ridden: a feature-state change, no data reload.
                        for (name, ids) in [("oneStreet", [4_242]), ("tenthOfStreets", Array(stride(from: 0, to: 136_000, by: 10)))] {
                            await run.measure(name) { done in
                                mapView.mapboxMap.onMapIdle.observeNext { _ in done() }.store(in: &coordinator.cancelables)
                                for id in ids { mapView.mapboxMap.setFeatureState(sourceId: "bench-0", featureId: String(id), state: ["ridden": true]) { _ in } }
                            }
                        }
                        run.complete()
                    }
                }.store(in: &coordinator.cancelables)
            }
        }.store(in: &coordinator.cancelables)
        return mapView
    }

    func updateUIView(_ uiView: MapView, context: Context) {}
}

/// MapKit at its best: one MKMultiPolyline per state, drawn by a single renderer each.
private struct StreetnavBenchMapKit: UIViewRepresentable {
    let run: StreetnavBenchRun

    func makeCoordinator() -> Coordinator { Coordinator(run: run) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        let first = StreetnavMapBenchmark.tour[0]
        map.region = StreetnavMapBenchmark.region(center: first.center, span: first.span)
        context.coordinator.map = map
        Task { await context.coordinator.load() }
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let run: StreetnavBenchRun
        weak var map: MKMapView?
        private var waitingForRender = false
        private var rendered: (() -> Void)?
        private var groups: [String: [MKPolyline]] = [:]
        private var overlays: [String: MKMultiPolyline] = [:]

        init(run: StreetnavBenchRun) { self.run = run }

        func load() async {
            let urls = StreetnavMapBenchmark.files(for: run.data)
            let start = CACurrentMediaTime()
            let lines = await Task.detached { urls.flatMap { (try? StreetnavMapBenchmark.readLines($0, defaultState: "track")) ?? [] } }.value
            run.dataRead(lines: lines.count, points: lines.reduce(0) { $0 + $1.coordinates.count }, milliseconds: (CACurrentMediaTime() - start) * 1000)
            run.startLoading()
            groups = Dictionary(grouping: lines, by: \.state).mapValues { group in group.map { MKPolyline(coordinates: $0.coordinates, count: $0.coordinates.count) } }
            waitingForRender = true
            for state in groups.keys { replaceOverlay(state) }
        }

        private func replaceOverlay(_ state: String) {
            if let old = overlays[state] { map?.removeOverlay(old) }
            let multi = MKMultiPolyline(groups[state] ?? [])
            multi.title = state
            overlays[state] = multi
            map?.addOverlay(multi)
        }

        /// MapKit has no per-line state: a street changing colour moves to another multi-polyline, rebuilt and redrawn whole.
        private func markRidden(count: Int, done: @escaping () -> Void) {
            let moving = Array((groups["untraveled"] ?? []).prefix(count))
            groups["untraveled"] = Array((groups["untraveled"] ?? []).dropFirst(count))
            groups["ridden", default: []].append(contentsOf: moving)
            replaceOverlay("untraveled")
            replaceOverlay("ridden")
            // MapKit says nothing when overlay tiles are redrawn: this times the main-thread work only.
            done()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let multi = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            renderer.strokeColor = multi.title == "ridden" ? .systemGreen : multi.title == "traveled" ? .systemGray : .systemBlue
            renderer.lineWidth = 1.5
            return renderer
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            if let rendered { self.rendered = nil; rendered(); return }
            guard waitingForRender else { return }
            waitingForRender = false
            run.dataShown()
            Task {
                await run.runTour { center, span, _ in
                    mapView.setRegion(StreetnavMapBenchmark.region(center: center, span: span), animated: true)
                }
                let untraveled = groups["untraveled"]?.count ?? 0
                await run.measure("oneStreet") { done in markRidden(count: 1, done: done) }
                await run.measure("tenthOfStreets") { done in markRidden(count: untraveled / 10, done: done) }
                run.complete()
            }
        }
    }
}

/// MapKit the way the app draws today: one SwiftUI MapPolyline per line.
private struct StreetnavBenchSwiftUIMap: View {
    @ObservedObject var run: StreetnavBenchRun
    @State private var lines: [IndexedLine] = []
    @State private var position = MapCameraPosition.region(StreetnavMapBenchmark.region(center: StreetnavMapBenchmark.tour[0].center, span: StreetnavMapBenchmark.tour[0].span))

    struct IndexedLine: Identifiable {
        let id: Int
        let line: StreetnavMapBenchmark.Line
    }

    var body: some View {
        Map(position: $position) {
            ForEach(lines) { item in
                MapPolyline(coordinates: item.line.coordinates)
                    .stroke(item.line.state == "traveled" ? Color.gray : Color.blue, lineWidth: 1.5)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .task {
            let urls = StreetnavMapBenchmark.files(for: run.data)
            let start = CACurrentMediaTime()
            let read = await Task.detached { urls.flatMap { (try? StreetnavMapBenchmark.readLines($0, defaultState: "track")) ?? [] } }.value
            run.dataRead(lines: read.count, points: read.reduce(0) { $0 + $1.coordinates.count }, milliseconds: (CACurrentMediaTime() - start) * 1000)
            run.startLoading()
            lines = read.enumerated().map { IndexedLine(id: $0.offset, line: $0.element) }
            // SwiftUI gives no render callback: the next turn of the main loop is the best available marker.
            try? await Task.sleep(for: .milliseconds(16))
            run.dataShown()
            await run.runTour { center, span, duration in
                withAnimation(.easeInOut(duration: duration)) {
                    position = .region(StreetnavMapBenchmark.region(center: center, span: span))
                }
            }
            run.complete()
        }
    }
}
#endif
