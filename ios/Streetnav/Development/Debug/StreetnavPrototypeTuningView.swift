import SwiftUI

#if DEBUG
struct StreetnavPrototypeTuningView: View {
    @StateObject private var model = StreetnavPrototypeViewModel()
    @State private var selectedPhase: StreetnavMotion.Phase = .plannerPresentation
    @State private var scheme: ColorScheme = .light
    @State private var dynamicType: DynamicTypeSize = .large

    var body: some View {
        HStack(spacing: 0) {
            StreetnavRecommendedView(model: model)
                .preferredColorScheme(scheme)
                .dynamicTypeSize(dynamicType)
                .frame(maxWidth: .infinity)
                .clipShape(Rectangle())

            Divider()

            Form {
                Section("Etat") {
                    Picker("Prototype", selection: $model.flowState) {
                        ForEach(PrototypeFlowState.allCases) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }
                    Picker("Apparence", selection: $scheme) {
                        Text("Clair").tag(ColorScheme.light)
                        Text("Sombre").tag(ColorScheme.dark)
                    }
                    Picker("Dynamic Type", selection: $dynamicType) {
                        Text("Normal").tag(DynamicTypeSize.large)
                        Text("Tres grand").tag(DynamicTypeSize.accessibility3)
                    }
                    Picker("GPS", selection: $model.gpsQuality) {
                        ForEach(GPSQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                }

                Section("Carte") {
                    Slider(value: $model.tuning.routeLineWidth, in: 4...16) { Text("Largeur route") }
                    LabeledContent("Largeur", value: model.tuning.routeLineWidth, format: .number.precision(.fractionLength(1)))
                    Slider(value: $model.tuning.overlayOpacity, in: 0.35...1) { Text("Opacite") }
                    Slider(value: $model.tuning.mapPitch, in: 0...70) { Text("Pitch") }
                    Slider(value: $model.tuning.mapZoom, in: 12...18) { Text("Zoom") }
                }

                Section("Motion") {
                    Slider(value: $model.tuning.springResponse, in: 0.18...0.8) { Text("Reponse") }
                    Slider(value: $model.tuning.springDamping, in: 0.55...1) { Text("Amorti") }
                    Slider(value: $model.tuning.transitionDuration, in: 0.05...0.6) { Text("Duree") }
                    Slider(value: $model.tuning.staggerDelay, in: 0...0.18) { Text("Decalage") }
                    Toggle("Simuler haptique", isOn: $model.tuning.simulateHaptics)
                    Toggle("Simuler Reduire les animations", isOn: $model.tuning.simulateReducedMotion)
                }

                Section("Integrations") {
                    Picker("Watch", selection: $model.watch.state) {
                        ForEach(DeviceConnectionState.allCases) { state in
                            Text(state.label).tag(state)
                        }
                    }
                    Picker("VanMoof", selection: $model.bike.state) {
                        ForEach(DeviceConnectionState.allCases) { state in
                            Text(state.label).tag(state)
                        }
                    }
                    Picker("Strava", selection: $model.integrations.stravaSync) {
                        ForEach(SyncState.allCases) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }
                    Toggle("Hors ligne", isOn: $model.integrations.isOffline)
                }

                Section("Phases") {
                    Picker("Phase", selection: $selectedPhase) {
                        ForEach(StreetnavMotion.Phase.allCases) { phase in
                            Text(phase.rawValue).tag(phase)
                        }
                    }
                    Button("Rejouer") { replay(selectedPhase) }
                }
            }
            .frame(width: 390)
        }
    }

    private func replay(_ phase: StreetnavMotion.Phase) {
        switch phase {
        case .plannerPresentation:
            model.flowState = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + model.tuning.staggerDelay) { model.flowState = .planner }
        case .routeResultAppearance:
            model.flowState = .planner
            DispatchQueue.main.asyncAfter(deadline: .now() + model.tuning.staggerDelay) { model.flowState = .routePreview }
        case .navigationStart:
            model.flowState = .readiness
            DispatchQueue.main.asyncAfter(deadline: .now() + model.tuning.staggerDelay) { model.flowState = .navigating }
        case .newStreetCompletion:
            model.flowState = .navigating
            DispatchQueue.main.asyncAfter(deadline: .now() + model.tuning.staggerDelay) { model.completeNewStreet() }
        case .arrivalSummary:
            model.flowState = .navigating
            DispatchQueue.main.asyncAfter(deadline: .now() + model.tuning.staggerDelay) { model.flowState = .arrived }
        }
    }
}
#endif
