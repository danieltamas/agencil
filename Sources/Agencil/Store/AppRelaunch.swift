import AppKit

/// Restart and Quit of the running app. A restart opens a fresh instance of this bundle, which waits for this one to exit.
enum AppRelaunch {
    @MainActor static func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "agencil-restart", Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        NSApplication.shared.terminate(nil)
    }

    @MainActor static func quit() { NSApplication.shared.terminate(nil) }

    /// A menu bar app is not frontmost: without this the Settings window opens behind whatever is.
    @MainActor static func activate() { NSApp.activate(ignoringOtherApps: true) }
}
