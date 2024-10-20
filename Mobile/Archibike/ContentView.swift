//
//  ContentView.swift
//  Archibike
//
//  Created by Félix Chevalier on 14/06/2024.
//

import SwiftUI
@_spi(Experimental) import MapboxMaps


struct ContentView: View {
    
    var body: some View {
        ZStack {
            BikeMap()
            OverlayHome()
            
        }
    }
}

#Preview {
    ContentView()
}
