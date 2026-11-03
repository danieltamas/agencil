import AppKit

/// The system file picker, the one way a view asks the owner for files.
enum FilePicker {
    @MainActor static func choose(limit: Int) -> [String] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Attach up to \(limit) files"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
}
