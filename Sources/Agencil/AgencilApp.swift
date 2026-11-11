import AgencilCore
import SwiftUI

enum MenuTitle {
    static func text(version: String) -> String { "Agencil \(version)" }
}

@main
struct AgencilApp: App {
    @State private var store: PanelStore
    /// Held for the app's lifetime: `body` runs again whenever the panel's data changes, and a store built inside it
    /// would be replaced each time, dropping any sheet open in Settings.
    @State private var settings: SettingsStore

    @State private var glyph = MenuBarGlyphModel()
    private let perf = PerfScenario.requested

    init() {
        let arguments = CommandLine.arguments
        if ScreenshotCommand.requested(arguments) { exit(ScreenshotCommand.run(arguments)) }
        if let perf = PerfScenario.requested {
            let stub = perf.store()
            _store = State(initialValue: stub)
            _settings = State(initialValue: SettingsStore())
            perf.launch(stub)
            return
        }
        LookLaunch.attach()
        AppBroker.start()
        UpdateStore.shared.start()
        _store = State(initialValue: PanelStore.launch())
        _settings = State(initialValue: SettingsStore.launch())
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarGlyph(model: glyph, live: perf == .menubar || (perf == nil && store.liveCount > 0))
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(store: settings)
        }
    }
}
