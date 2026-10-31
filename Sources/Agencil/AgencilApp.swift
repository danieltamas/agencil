import AgencilCore
import SwiftUI

enum MenuTitle {
    static func text(version: String) -> String { "Agencil \(version)" }
}

@main
struct AgencilApp: App {
    @State private var store: PanelStore

    @State private var glyph = MenuBarGlyphModel()
    private let perf = PerfScenario.requested

    init() {
        let arguments = CommandLine.arguments
        if ScreenshotCommand.requested(arguments) { exit(ScreenshotCommand.run(arguments)) }
        if let perf = PerfScenario.requested {
            let stub = perf.store()
            _store = State(initialValue: stub)
            perf.launch(stub)
            return
        }
        LookLaunch.attach()
        AppBroker.start()
        _store = State(initialValue: PanelStore.launch())
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarGlyph(model: glyph, live: perf == .menubar || (perf == nil && store.liveCount > 0))
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(store: SettingsStore.launch())
        }
    }
}
