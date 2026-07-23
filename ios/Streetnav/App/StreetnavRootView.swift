import SwiftUI

struct StreetnavRootView: View {
    #if DEBUG
    @State private var developerDestination: DeveloperDestination?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StreetnavRecommendedView()

            #if DEBUG
            Menu {
                Button("Galerie des directions") { developerDestination = .gallery }
                Button("Tuning lab") { developerDestination = .tuning }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .padding(.top, 62)
            .padding(.trailing, 16)
            .accessibilityLabel("Outils de developpement")
            .sheet(item: $developerDestination) { destination in
                switch destination {
                case .gallery:
                    StreetnavPrototypeGallery()
                case .tuning:
                    StreetnavPrototypeTuningView()
                }
            }
            #endif
        }
    }
}

#if DEBUG
private enum DeveloperDestination: Identifiable {
    case gallery
    case tuning
    var id: Int { hashValue }
}
#endif
