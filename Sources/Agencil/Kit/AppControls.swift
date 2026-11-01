import SwiftUI

/// Restart and Quit as quiet text controls with a glyph, the same in the panel footer and the Settings window.
struct AppControls: View {
    let restart: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: Space.xl) {
            control("Restart", symbol: "arrow.clockwise", help: "Quit Agencil and open it again", action: restart)
            control("Quit", symbol: "power", help: "Quit Agencil: no council sits until it runs again", action: quit)
        }
    }

    private func control(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
                Text(title).font(.house.badge).lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(lift: 0))
        .help(help)
    }
}
