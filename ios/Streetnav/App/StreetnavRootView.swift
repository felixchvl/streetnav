import SwiftUI

struct StreetnavRootView: View {
    var body: some View {
        #if DEBUG
        if let request = StreetnavMapBenchmark.request {
            StreetnavMapBenchmarkView(engine: request.engine, data: request.data)
        } else {
            StreetnavRecommendedView()
        }
        #else
        StreetnavRecommendedView()
        #endif
    }
}
