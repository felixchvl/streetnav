//
//  StreetnavApp.swift
//  Streetnav
//
//  Created by Félix Chevalier on 14/06/2024.
//

import MapboxMaps
import SwiftUI

@main
struct StreetnavApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // No Mapbox telemetry, for the map and the navigation alike: the switch of the map's (i) menu, turned off before
        // the first map is made.
        UserDefaults.standard.set(false, forKey: "MGLMapboxMetricsEnabled")
        Self.clearMapboxCacheAfterUpdate()
        // iOS only hands new Apple Health workouts to an app in the background if it asks again at every launch.
        StreetnavHealthSync.shared.startObserving()
    }

    var body: some Scene {
        WindowGroup {
            StreetnavRootView()
        }
        // Apple Health checked again whenever the app opens; leaving it books the next check in the background. The
        // streets ridden right now are followed, and the bike connected, while the app is on screen.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await StreetnavHealthSync.shared.check() }
                StreetnavLiveStreets.shared.start()
                // The bike for the map's chip; let go in the background, for the VanMoof app to reach it.
                #if DEBUG
                StreetnavVanMoofBike.shared.showSampleIfAsked()
                #endif
                Task { await StreetnavVanMoofBike.shared.connectIfSignedIn() }
            case .background:
                StreetnavHealthSync.shared.scheduleRefresh()
                StreetnavLiveStreets.shared.stop()
                StreetnavVanMoofBike.shared.disconnect()
            default: break
            }
        }
        .backgroundTask(.appRefresh(StreetnavHealthSync.refreshTask)) {
            await StreetnavHealthSync.shared.scheduleRefresh()
            await StreetnavHealthSync.shared.check()
        }
    }

    /// The Mapbox SDK this build uses, to bump with it.
    private static let mapboxVersion = "11.34.1"

    /// Mapbox keeps the Standard style it was served for a day, and serves each SDK the style it can draw: after an SDK
    /// update the cached one may lack what the new SDK brings (the HD roads of 11.33). The cache is cleared once after
    /// each update, before the first map loads, so that the new style comes at once.
    private static func clearMapboxCacheAfterUpdate() {
        let key = "streetnav.mapboxCacheVersion"
        guard UserDefaults.standard.string(forKey: key) != mapboxVersion else { return }
        MapboxMap.clearData { error in
            if error == nil { UserDefaults.standard.set(mapboxVersion, forKey: key) }
        }
    }
}
