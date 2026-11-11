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
    /// Held here for the same reason, so a Setup step in progress survives the panel's refreshes.
    @State private var setup: SetupStore

    @State private var glyph = MenuBarGlyphModel()
    private let perf = PerfScenario.requested

    init() {
        let arguments = CommandLine.arguments
        if ScreenshotCommand.requested(arguments) { exit(ScreenshotCommand.run(arguments)) }
        if let perf = PerfScenario.requested {
            let stub = perf.store()
            _store = State(initialValue: stub)
            _settings = State(initialValue: SettingsStore())
            _setup = State(initialValue: SetupStore(settings: nil))
            perf.launch(stub)
            return
        }
        LookLaunch.attach()
        AppBroker.start()
        UpdateStore.shared.start()
        _store = State(initialValue: PanelStore.launch())
        let settings = SettingsStore.launch()
        _settings = State(initialValue: settings)
        _setup = State(initialValue: SetupStore(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarGlyph(model: glyph, live: perf == .menubar || (perf == nil && store.liveCount > 0))
                .modifier(SetupLauncher(setup: setup))
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(store: settings)
        }
        Window("Set up Agencil", id: SetupStore.windowID) {
            SetupView(store: setup)
        }
        .windowResizability(.contentSize)
    }
}

/// Opens Setup once at launch while the config has no seat (docs/U37-SPEC.md). It hangs off the menu bar label, the one
/// view that appears at launch without the owner opening anything.
private struct SetupLauncher: ViewModifier {
    let setup: SetupStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard setup.claimLaunchOpen() else { return }
            AppRelaunch.activate()
            openWindow(id: SetupStore.windowID)
        }
    }
}
