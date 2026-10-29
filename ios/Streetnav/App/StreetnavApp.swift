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
        // iOS only hands new Apple Health workouts to an app in the background if it asks again at every launch.
        StreetnavHealthSync.shared.startObserving()
    }

    var body: some Scene {
        WindowGroup {
            StreetnavRootView()
        }
    }
}
