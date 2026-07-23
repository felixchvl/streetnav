import SwiftUI

struct OverlayHome: View {
    var body: some View {
        Spacer()
        Text("Petit exemple de ce qui pourrait etre montre")
            .frame(height: 50)
            .background(Color.green)
    }
}

struct OverlayHome_Previews: PreviewProvider {
    static var previews: some View {
        OverlayHome()
            .previewDisplayName("Overlay Home")
    }
}
