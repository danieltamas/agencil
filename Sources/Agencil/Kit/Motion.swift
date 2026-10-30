import SwiftUI

extension EnvironmentValues {
    /// Whether the panel is on screen. Perpetual motion pauses while it is not.
    @Entry var panelVisible = true
    /// Drawn once into an image (screenshots): no appear animation runs, lists lay out flat and fully shown.
    @Entry var stillImage = false
    /// The fixed clock of a render: relative times read the same in every run.
    @Entry var demoNow: Date?
}

/// Rows rise into place, one after another, the first time a list shows.
struct RiseIn: ViewModifier {
    let index: Int
    @Environment(\.stillImage) private var stillImage
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || stillImage ? 1 : 0)
            .offset(y: shown || stillImage ? 0 : 10)
            .onAppear {
                withAnimation(Motion.spring.delay(Double(min(index, Motion.riseIndexCap)) * Motion.riseDelay)) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }

    /// The one transition views may use for something that appears or leaves.
    func houseTransition() -> some View {
        transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}
