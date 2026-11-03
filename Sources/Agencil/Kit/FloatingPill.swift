import SwiftUI

/// The one primary "create" action of a tab: a prominent pill that floats over the bottom-trailing corner of the
/// scrolling content, above the footer (docs/DESIGN.md "Floating action"). Place it with `floatingAction`.
struct FloatingPill: View {
    let title: String
    var symbol = "plus"
    var disabled = false
    let action: () -> Void

    var body: some View {
        PillButton(title: title, symbol: symbol, prominent: true, disabled: disabled, action: action)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

extension View {
    /// Floats `pill` over the bottom-trailing corner of this container; `nil` shows none. The list inside keeps its last
    /// row clear with `Size.floatingClearance`.
    func floatingAction<Pill: View>(_ pill: Pill?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let pill {
                pill.padding(.trailing, Space.panelInset).padding(.bottom, Space.l)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }
}
