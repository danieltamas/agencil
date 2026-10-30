import SwiftUI

/// A card that lifts its core on hover and opens something on click: idle, hover, pressed.
struct HoverCard<Content: View>: View {
    var accent: Color?
    let action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Bezel(fill: hovering && action != nil ? Theme.coreHover : Theme.core) {
            HStack(spacing: 0) {
                if let accent {
                    Capsule().fill(accent.gradient).frame(width: 3).padding(.vertical, 10).padding(.leading, Space.s)
                        .shadow(color: accent.opacity(0.6), radius: 4)
                }
                content.padding(.horizontal, Space.l).padding(.vertical, 10)
            }
        }
        .scaleEffect(pressed ? 0.99 : hovering && action != nil ? 1.006 : 1)
        .opacity(pressed ? 0.85 : 1)
        .animation(Motion.snappy, value: pressed)
        .contentShape(Rectangle())
        // A button gesture, not a tap: it reports the press, and a button inside the card still gets its own click.
        ._onButtonGesture(pressing: { pressed = $0 && action != nil }, perform: { action?() })
        .pointingHandCursor(action != nil)
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
    }
}
