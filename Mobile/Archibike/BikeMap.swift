//
//  BikeMap.swift
//  Archibike
//
//  Created by Félix Chevalier on 22/06/2024.
//

import SwiftUI
@_spi(Experimental) import MapboxMaps

struct BikeMap: View {
    var body: some View {
        let myMapInitOptions = MapInitOptions(styleURI: StyleURI(rawValue: "mapbox://styles/felixchvl/clxni2hhh000h01pa760oc6y9"))
        let center = CLLocationCoordinate2D(latitude: 48.85165079999999, longitude: 2.3624705)
        Map(initialViewport: .camera(center: center, zoom: 18, bearing: 50, pitch: 60))
            .ignoresSafeArea()
        
    }
}

#Preview {
    BikeMap()
}
