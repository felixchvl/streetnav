//
//  StreetnavApp.swift
//  Streetnav
//
//  Created by Félix Chevalier on 14/06/2024.
//

import SwiftUI

@main
struct StreetnavApp: App {
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
    }
}
