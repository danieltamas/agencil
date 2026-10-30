import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

@Suite(.serialized)
@MainActor
struct HouseKitLayoutTests {
    private let tolerance: CGFloat = 0.5

    @Test func panelAndControlsInEveryLook() {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        #expect(Size.panelWidth == 404)
        #expect(Size.control == 28)
        #expect(!KitGallery.controls.isEmpty)
        for look in Look.allCases {
            Appearance.shared.look = look
            let panel = HouseRender.fittingSize(of: KitGallery())
            #expect(abs(panel.width - Size.panelWidth) <= tolerance, "Panel: \(look)")
            for control in KitGallery.controls {
                let size = HouseRender.fittingSize(of: control.view)
                #expect(abs(size.height - Size.control) <= tolerance, "\(control.name): \(look), \(size)")
            }
        }
    }

    @Test func longNamesFitOrWrapAndGalleryStaysWithinPanel() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        #expect(DemoStore.longRepo.count >= 48)
        #expect(DemoStore.longModelId.count >= 60)
        #expect(DemoStore.longReason.count >= 120)
        let available = Size.panelWidth - 2 * Space.panelInset
        for look in Look.allCases {
            Appearance.shared.look = look
            // Mirror the gallery's actual modifiers, including its line limits. Do not add
            // fixedSize(vertical: true) here: that could conceal truncation in the gallery.
            let repo = Text(DemoStore.longRepo).font(.house.rowTitle)
                .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            let repoIdeal = Text(DemoStore.longRepo).font(.house.rowTitle)
            assertFitsOrWraps(repo, ideal: repoIdeal, width: available, name: "repo \(look)")
            let reason = Text(DemoStore.longReason).font(.house.meta)
                .foregroundStyle(Theme.textTertiary).detailLines()
            let reasonIdeal = Text(DemoStore.longReason).font(.house.meta)
            assertFitsOrWraps(reason, ideal: reasonIdeal, width: available, name: "reason \(look)")

            // Model identifiers are explicitly permitted to truncate in the middle.
            let model = Text(DemoStore.longModelId).font(.house.control)
                .lineLimit(1).truncationMode(.middle)
            let modelSize = HouseRender.fittingSize(of: model, width: available)
            #expect(modelSize.width <= available + tolerance)
            #expect(modelSize.height > 0)
            let gallerySize = HouseRender.fittingSize(of: KitGallery())
            #expect(gallerySize.width <= Size.panelWidth + tolerance)
            let data = try HouseRender.png(KitGallery(), look: look, scale: 1, now: DemoStore.now)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 404, "Gallery bounds: \(look)")
            #expect(bitmap.pixelsHigh > 0)
        }
    }

    private func assertFitsOrWraps<V: View, I: View>(
        _ view: V, ideal: I, width: CGFloat, name: String
    ) {
        let natural = HouseRender.fittingSize(of: ideal)
        let measured = HouseRender.fittingSize(of: view, width: width)
        // An unrestricted copy supplies the height needed to show *all* the text.
        // Merely growing by one line would let a two-line ellipsis pass unnoticed.
        let complete = HouseRender.fittingSize(
            of: ideal.fixedSize(horizontal: false, vertical: true), width: width
        )
        #expect(measured.width <= width + tolerance, "Bounds: \(name)")
        #expect(measured.height > 0)
        if natural.width > width + tolerance {
            #expect(measured.height > natural.height + tolerance, "Must wrap: \(name)")
            #expect(measured.height >= complete.height - tolerance, "Must show all lines: \(name)")
        }
    }

    @Test func emptyStatesRenderInEveryLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        for look in Look.allCases {
            Appearance.shared.look = look
            let view = EmptyState(symbol: "tray", title: "No councils yet", detail: "Ask one from the CLI or an agent.")
            let size = HouseRender.fittingSize(of: view, width: Size.panelWidth)
            #expect(size.width > 0 && size.height > 0)
            let data = try HouseRender.png(view, look: look, scale: 1, now: DemoStore.now, width: Size.panelWidth)
            #expect(!data.isEmpty)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        }
    }

    @Test func settingsComponentsFitMinimumWindowInEveryLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        #expect(Size.settingsMin == CGSize(width: 760, height: 540))
        let contentWidth = Size.settingsMin.width - Size.settingsSidebar - 2 * Space.pane
        for look in Look.allCases {
            Appearance.shared.look = look
            let content = VStack(alignment: .leading, spacing: Space.xxl) {
                PaneHeader(symbol: "slider.horizontal.3", eyebrow: "Settings", color: Theme.accent,
                           title: "General", detail: "Choose how councils work.")
                SettingsCard(title: "Notifications", detail: "Tell me when a council reaches a verdict.") {
                    SettingsRow(title: "Seats", detail: DemoStore.seats.joined(separator: ", ")) {
                        Chip(text: "5", color: Theme.color(for: .unknown))
                    }
                }
            }
            let size = HouseRender.fittingSize(of: content, width: contentWidth)
            #expect(size.width <= contentWidth + tolerance)
            #expect(size.height > 0)
            let window = HStack(spacing: 0) {
                Color.clear.frame(width: Size.settingsSidebar)
                ScrollView(.vertical) { content.padding(Space.pane) }
            }
            let windowSize = HouseRender.fittingSize(
                of: window, width: Size.settingsMin.width, height: Size.settingsMin.height
            )
            #expect(windowSize.width <= Size.settingsMin.width + tolerance)
            let data = try HouseRender.png(window, look: look, scale: 1, now: DemoStore.now,
                                           width: Size.settingsMin.width, height: Size.settingsMin.height)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 760 && bitmap.pixelsHigh == 540)
        }
    }

    @Test func lookPersistsOnlyThroughConfigStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let store = ConfigStore(directory: directory)
        let persistence = LookStorage.persistence(store: store)
        try persistence.save("solidGlass")
        #expect(try store.read().values["look"] == "solidGlass")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
        let fresh = Appearance(persistence: LookStorage.persistence(store: ConfigStore(directory: directory)))
        #expect(fresh.look == .solidGlass)
        try fresh.choose(.solidGlassLight)
        #expect(try store.read().values["look"] == "solidGlassLight")
        #expect(UserDefaults.standard.string(forKey: "look") == nil)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Agencil")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("UserDefaults"), "Unexpected UserDefaults: \(file.lastPathComponent)")
        }
        #expect(scanned > 0)
    }

    @Test func rendersAreByteIdenticalInEveryLook() throws {
        for look in Look.allCases {
            let first = try HouseRender.png(KitGallery(), look: look, scale: 1, now: DemoStore.now)
            let second = try HouseRender.png(KitGallery(), look: look, scale: 1, now: DemoStore.now)
            #expect(!first.isEmpty)
            #expect(first == second, "Non-deterministic gallery: \(look)")
        }
    }
}
