import SwiftUI

/// Restart and Quit, the same two chips in the panel footer and the Settings window.
struct AppControls: View {
    let restart: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            ChipButton(title: "Restart", action: restart)
            ChipButton(title: "Quit", action: quit)
        }
    }
}
