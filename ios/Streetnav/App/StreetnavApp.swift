//
//  StreetnavApp.swift
//  Streetnav
//
//  Created by Félix Chevalier on 14/06/2024.
//

import SwiftUI

@main
struct StreetnavApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // No Mapbox telemetry, for the map and the navigation alike: the switch of the map's (i) menu, turned off before
        // the first map is made.
        UserDefaults.standard.set(false, forKey: "MGLMapboxMetricsEnabled")
        // iOS only hands new Apple Health workouts to an app in the background if it asks again at every launch.
        StreetnavHealthSync.shared.startObserving()
    }

    var body: some Scene {
        WindowGroup {
            StreetnavRootView()
        }
        // Apple Health checked again whenever the app opens; leaving it books the next check in the background. The
        // streets ridden right now are followed while the app is on screen.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await StreetnavHealthSync.shared.check() }
                StreetnavLiveStreets.shared.start()
            case .background:
                StreetnavHealthSync.shared.scheduleRefresh()
                StreetnavLiveStreets.shared.stop()
            default: break
            }
        }
        .backgroundTask(.appRefresh(StreetnavHealthSync.refreshTask)) {
            await StreetnavHealthSync.shared.scheduleRefresh()
            await StreetnavHealthSync.shared.check()
        }
    }
}
