import AgencilCore
import SwiftUI

enum MenuTitle {
    static func text(version: String) -> String { "Agencil \(version)" }
}

@main
struct AgencilApp: App {
    init() {
        let arguments = CommandLine.arguments
        if ScreenshotCommand.requested(arguments) { exit(ScreenshotCommand.run(arguments)) }
        LookLaunch.attach()
    }

    var body: some Scene {
        MenuBarExtra("Agencil", systemImage: "circle.hexagongrid") {
            Text(MenuTitle.text(version: AgencilVersion.current()))
        }
    }
}
