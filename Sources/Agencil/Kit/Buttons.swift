import SwiftUI

/// A round, light-weight icon button for toolbars and rows.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconButton * 0.46, weight: .regular))
                .foregroundStyle(hovering ? Theme.textPrimary : tint)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .background(Theme.wash.opacity(hovering ? 0.10 : 0.05), in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.9, hit: AnyShape(Circle()), lift: 0))
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(help)
    }
}

/// A pill button with its trailing icon in a disc of its own, flush with the right edge. Exactly `Size.control` tall.
struct PillButton: View {
    let title: String
    var symbol = "arrow.up.right"
    var prominent = true
    var disabled = false
    let action: () -> Void
    /// Also off when a parent says `.disabled(...)`: it looks off either way.
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private static let disc = Size.control - 8

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.house.control).lineLimit(1)
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: Self.disc, height: Self.disc)
                    .background((prominent ? Theme.canvas : Theme.wash).opacity(prominent ? 0.18 : 0.08), in: Circle())
                    .offset(x: hovering ? 1.5 : 0, y: hovering ? -1 : 0)
                    .scaleEffect(hovering ? 1.06 : 1)
            }
            .padding(.leading, Space.panelInset)
            .padding(.trailing, Space.xs)
            .frame(height: Size.control)
            .foregroundStyle(prominent ? Theme.canvas : Theme.textPrimary)
            .background {
                if prominent { Capsule().fill(Theme.brand) } else { Capsule().fill(Theme.wash.opacity(Theme.opacity.wash)) }
            }
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(0.25) : Theme.wash.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressStyle(scale: 0.97, hit: AnyShape(Capsule()), lift: 0))
        .opacity(disabled || !isEnabled ? 0.4 : 1)
        .disabled(disabled)
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering && isEnabled && !disabled } }
    }
}
