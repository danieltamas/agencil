import AgencilCore
import AppKit
import SwiftUI
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
                for pane in [SettingsPane.general, .seats, .models, .access, .apps, .about] {
                    try HouseRender.write(SettingsView(store: SettingsStore.demo(), pane: pane).frame(width: Size.settingsMin.width, height: height(of: pane)),
                                          to: directory.appendingPathComponent("settings-\(pane.rawValue)\(suffix).png"), look: look, scale: scale,
                                          now: DemoStore.now)
                }
                try HouseRender.write(addModelSheet(), to: directory.appendingPathComponent("models-add\(suffix).png"), look: look, scale: scale, now: DemoStore.now)
                if looks.count > 1 { try copy(directory, "settings-access-\(look.rawValue).png", "access-full-\(look.rawValue).png") }
            }
            let off = SettingsView(store: SettingsStore.demo(accessOn: false), pane: .access)
                .frame(width: Size.settingsMin.width, height: height(of: .access))
            try HouseRender.write(off, to: directory.appendingPathComponent("access-off.png"), look: looks[0], scale: scale, now: DemoStore.now)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    /// The apps list and About are longer than the window: their shots show every card, not the scrolled-off top.
    private static func height(of pane: SettingsPane) -> CGFloat {
        pane == .apps ? Size.settingsMin.height * 2.4 : pane == .models ? Size.settingsMin.height * 2 : pane == .access ? Size.settingsMin.height * 3 : pane == .about ? Size.settingsMin.height * 1.5 : Size.settingsMin.height
    }

    /// The full-height access pane under the name the review asks for.
    private static func copy(_ directory: URL, _ from: String, _ to: String) throws {
        let target = directory.appendingPathComponent(to)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(from), to: target)
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
}

extension ScreenshotCommand {
    /// The Add model sheet with a model typed in, at the sheet's own width.
    static func addModelSheet() -> some View {
        let catalog = SettingsStore.demo().catalog
        catalog.startAdd()
        catalog.form = .init(id: "harbor-review-2", harness: "opencode", note: "tuned for the checkout repo")
        return houseSheetShot(title: catalog.formTitle, detail: "Saved to config.json; seats can name it at once.", primary: "Save") {
            ModelForm(catalog: catalog)
        }
        .frame(width: Size.modalWidth)
    }
}
