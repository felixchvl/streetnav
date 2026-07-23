import CoreLocation
import MapKit
import SwiftUI

#if canImport(MapboxMaps)
@_spi(Experimental) import MapboxMaps
#endif

struct BikeMap: View {
    private let center = CLLocationCoordinate2D(latitude: 48.85165079999999, longitude: 2.3624705)

    var body: some View {
        #if canImport(MapboxMaps)
        Map(initialViewport: .camera(center: center, zoom: 18, bearing: 50, pitch: 60))
            .ignoresSafeArea()
        #else
        Map(position: .constant(.region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))))
            .ignoresSafeArea()
        #endif
    }
}

struct BikeMap_Previews: PreviewProvider {
    static var previews: some View {
        BikeMap()
            .previewDisplayName("Bike Map")
    }
}
