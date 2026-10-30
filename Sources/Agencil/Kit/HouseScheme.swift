import SwiftUI

extension View {
    /// The one place the colour scheme and the look are applied to a root (panel, Settings, every sheet).
    func houseScheme() -> some View {
        modifier(HouseScheme())
    }
}

private struct HouseScheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(Appearance.shared.look.palette.scheme)
            .background(Backdrop())
    }
}
