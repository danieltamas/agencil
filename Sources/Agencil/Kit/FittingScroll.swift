import SwiftUI

/// A scroll view that takes its content's height, up to `limit`, so a menu bar window sizes to what it shows
/// instead of collapsing to a sliver (a bare `ScrollView` reports almost no ideal height).
struct FittingScroll<Content: View>: View {
    var limit: CGFloat = Size.panelListLimit
    @ViewBuilder let content: Content
    @State private var natural: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background {
                GeometryReader { proxy in Color.clear.preference(key: NaturalHeight.self, value: proxy.size.height) }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: min(max(natural, 1), limit))
        .onPreferenceChange(NaturalHeight.self) { natural = $0 }
    }
}

private struct NaturalHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
