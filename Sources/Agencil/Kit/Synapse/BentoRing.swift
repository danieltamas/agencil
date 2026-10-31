import SwiftUI

/// The council ring as the in-session bento tile's footer: a fixed height, so the tile keeps its size.
struct BentoRing<Ring: View>: View {
    @ViewBuilder let ring: Ring

    var body: some View {
        ring.frame(maxWidth: .infinity, maxHeight: Size.bentoRing)
    }
}
