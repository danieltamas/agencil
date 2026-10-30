import SwiftUI

/// The one place a press starts a Task. The press holds `id` in `inFlight` while the action runs, so the button
/// shows it and a second press meanwhile is nothing. Ids are stable per target (`stop:<run>`, `ask:<seat>`), so
/// the same action offered twice shares one state. The press guard refuses a `Task` anywhere else in `Views/`.
struct AsyncPress<Content: View>: View {
    @Environment(\.inFlight) private var shared
    @State private var local = InFlightActions()
    let id: String
    let action: () async -> Void
    @ViewBuilder let content: (_ running: Bool, _ press: @escaping () -> Void) -> Content

    var body: some View {
        let inFlight = shared ?? local
        return content(inFlight.isRunning(id)) {
            Task { await inFlight.perform(id) { await action() } }
        }
    }
}

/// A PillButton whose press awaits: dimmed, renamed and unpressable until the action returns.
struct AsyncPillButton: View {
    let title: String
    var runningTitle: String?
    var symbol = "arrow.up.right"
    var prominent = true
    var disabled = false
    let id: String
    let action: () async -> Void

    var body: some View {
        AsyncPress(id: id, action: action) { running, press in
            PillButton(title: running ? runningTitle ?? title : title, symbol: symbol, prominent: prominent,
                       disabled: disabled || running, action: press)
        }
    }
}

/// An IconButton whose press awaits: dimmed and unpressable until the action returns.
struct AsyncIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    var disabled = false
    let id: String
    let action: () async -> Void

    var body: some View {
        AsyncPress(id: id, action: action) { running, press in
            IconButton(symbol: symbol, help: help, tint: tint, action: press)
                .disabled(disabled || running)
                .opacity(disabled || running ? 0.4 : 1)
        }
    }
}
