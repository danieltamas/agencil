import AgencilCore
import SwiftUI

enum MenuTitle {
    static func text(version: String) -> String { "Agencil \(version)" }
}

@main
struct AgencilApp: App {
    @State private var store: PanelStore

    init() {
        let arguments = CommandLine.arguments
        if ScreenshotCommand.requested(arguments) { exit(ScreenshotCommand.run(arguments)) }
        LookLaunch.attach()
        AppBroker.start()
        _store = State(initialValue: PanelStore.launch())
    }

    var body: some Scene {
        MenuBarExtra("Agencil", systemImage: "circle.hexagongrid") {
            PanelView(store: store)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(store: SettingsStore.launch())
        }
    }
}
