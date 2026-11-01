import AgencilCore
import AppKit
import Foundation

/// `Agencil --render-screenshots <dir> [--all-looks] [--look <name>] [--scale N]`: every shot the app can draw,
/// from `DemoStore` only. Nothing is read from or written to this Mac's `~/.agencil`, and nothing reaches the
/// screen. The set grows with each unit that adds a screen.
@MainActor
enum ScreenshotCommand {
    static let flag = "--render-screenshots"

    static func requested(_ arguments: [String]) -> Bool { arguments.contains(flag) }

    /// Returns the process exit code.
    static func run(_ arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            FileHandle.standardError.write(Data("usage: Agencil --render-screenshots <dir> [--all-looks] [--look <name>] [--scale N]\n".utf8))
            return 2
        }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let scale = value(after: "--scale", in: arguments).flatMap(Double.init).map { CGFloat($0) } ?? 2
        let looks: [Look]
        if arguments.contains("--all-looks") {
            looks = Look.allCases
        } else if let name = value(after: "--look", in: arguments) {
            guard let look = Look(rawValue: name) else {
                FileHandle.standardError.write(Data("unknown look \(name)\n".utf8))
                return 2
            }
            looks = [look]
        } else {
            looks = [.agencil]
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for look in looks {
                let name = looks.count == 1 ? "kit-gallery.png" : "kit-gallery-\(look.rawValue).png"
                try HouseRender.write(KitGallery(), to: directory.appendingPathComponent(name), look: look, scale: scale)
                let suffix = looks.count == 1 ? "" : "-\(look.rawValue)"
                for tab in ["threads", "sittings", "findings", "seats"] {
                    try HouseRender.write(PanelView(store: PanelStore.demo(), tab: tab), to: directory.appendingPathComponent("panel-\(tab)\(suffix).png"), look: look, scale: scale)
                }
                for pane in [SettingsPane.general, .seats, .access, .apps, .about] {
                    try HouseRender.write(SettingsView(store: SettingsStore.demo(), pane: pane).frame(width: Size.settingsMin.width, height: height(of: pane)),
                                          to: directory.appendingPathComponent("settings-\(pane.rawValue)\(suffix).png"), look: look, scale: scale,
                                          now: DemoStore.now)
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    /// The apps list and About are longer than the window: their shots show every card, not the scrolled-off top.
    private static func height(of pane: SettingsPane) -> CGFloat {
        pane == .apps ? Size.settingsMin.height * 2.4 : pane == .about ? Size.settingsMin.height * 1.5 : Size.settingsMin.height
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
}
