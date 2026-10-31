import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

/* API contract (Agencil module, visible through @testable import).
 Sources/Agencil/Store/SettingsStore.swift:
 @MainActor @Observable final class SettingsStore; static func demo() -> SettingsStore.
 demo() supplies synthetic settings only; no broker, timers or file writes.
 SettingsView.init(store: SettingsStore, pane: SettingsPane).
 SettingsPaneView.init(store: SettingsStore, pane: SettingsPane).
 enum SheetKind { case seat, council, route }
 NewObjectForm.init(store: SettingsStore, kind: SheetKind, problems: [String: String]).
 Each supplied problem is displayed once with ProblemText, including form.
 Existing SettingsPane.allCases, SettingsRow and HouseRender remain usable.
 No mutable production store properties or additional test hooks are assumed.
 */

@Suite(.serialized) @MainActor struct U9SettingsLayoutTests {
    private let kinds: [SheetKind] = [.seat, .council, .route]
    private let width: CGFloat = 760
    private let height: CGFloat = 540
    private let tolerance: CGFloat = 0.5

    @Test func everyPaneRendersAtMinimumWindowInEveryLook() throws {
        #expect(Size.settingsMin == CGSize(width: width, height: height))
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        for look in Look.allCases {
            Appearance.shared.look = look
            for pane in SettingsPane.allCases {
                let store = SettingsStore.demo()
                let window = SettingsView(store: store, pane: pane)
                // Unconstrained root measurement catches an oversized minimum frame.
                let natural = HouseRender.fittingSize(of: window)
                #expect(natural.width <= width + tolerance, "Window \(pane), \(look): \(natural)")
                try assertRender(window, look: look, offeredWidth: width, offeredHeight: height)
                // Measure the pane separately: a fixed outer window or ScrollView
                // must not hide a pane whose own content needs a horizontal scroll.
                let contentWidth = width - Size.settingsSidebar - 2 * Space.pane
                try assertRender(SettingsPaneView(store: store, pane: pane), look: look,
                                 offeredWidth: contentWidth)
            }
        }
    }

    @Test func everySheetRendersAtMinimumWindowInEveryLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        for look in Look.allCases {
            Appearance.shared.look = look
            for kind in kinds {
                let store = SettingsStore.demo()
                let form = NewObjectForm(store: store, kind: kind, problems: [:])
                let sheet = ModalFrame(title: "New object", content: form,
                    footer: ModalFooter(secondary: .init(title: "Cancel") {}, primary: .init(title: "Save") {}))
                let natural = HouseRender.fittingSize(of: sheet)
                #expect(natural.width <= width + tolerance && natural.height > 0)
                try assertRender(sheet, look: look, offeredWidth: width, offeredHeight: height)
                try assertRender(form, look: look, offeredWidth: Size.modalWidth - 2 * Space.xxl)
            }
        }
    }

    @Test func eachProblemAddsItsOwnVisibleProblemTextRow() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        for look in Look.allCases {
            Appearance.shared.look = look
            for kind in kinds {
                let keys: [String]
                switch kind {
                case .seat: keys = ["name", "harness", "model", "endpoint", "pin", "capSeconds", "form"]
                case .council: keys = ["name", "seats", "rule", "quorum", "form"]
                case .route: keys = ["callers", "target", "hopLimit", "form"]
                }
                let store = SettingsStore.demo()
                let contentWidth = Size.modalWidth - 2 * Space.xxl
                let plain = NewObjectForm(store: store, kind: kind, problems: [:])
                let baseline = HouseRender.fittingSize(of: plain, width: contentWidth)
                let message = "This value needs attention."
                let row = HouseRender.fittingSize(of: ProblemText(text: message), width: contentWidth)
                #expect(row.height > 0)
                var problems: [String: String] = [:]
                var previousHeight = baseline.height
                for key in keys {
                    problems[key] = message
                    let failed = NewObjectForm(store: store, kind: kind, problems: problems)
                    // Measure the form without a fixed height or a sheet ScrollView:
                    // clipping to the window would conceal missing error rows.
                    let size = HouseRender.fittingSize(of: failed, width: contentWidth)
                    #expect(size.height >= previousHeight + row.height - tolerance,
                            "ProblemText missing for \(kind).\(key), \(look)")
                    previousHeight = size.height
                    try assertRender(failed, look: look, offeredWidth: contentWidth)
                }
                #expect(previousHeight >= baseline.height + CGFloat(keys.count) * row.height - tolerance)
            }
        }
    }

    @Test func longestSyntheticSettingsNamesFitInEveryLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let repo = String(repeating: "harbor-checkout-", count: 4)
        let model = String(repeating: "local-model-long-context-", count: 3)
        let reason = String(repeating: "The endpoint closed before the answer completed. ", count: 3)
        #expect(repo.count >= 48 && model.count >= 60 && reason.count >= 120)
        let contentWidth = width - Size.settingsSidebar - 2 * Space.pane
        for look in Look.allCases {
            Appearance.shared.look = look
            let rows: [AnyView] = [
                AnyView(SettingsRow(title: repo, detail: model) { Chip(text: "down", color: Theme.unknown) }),
                AnyView(SettingsRow(title: model, detail: reason) { ChipButton(title: "Install for opencode") {} }),
                AnyView(SettingsRow(title: repo + " -> " + model, detail: reason) { Chip(text: "4 hops", color: Theme.unknown) })
            ]
            for row in rows { try assertRender(row, look: look, offeredWidth: contentWidth) }
            // Exercise long failure text on the real sheet as well as the row kit.
            for kind in kinds {
                try assertRender(NewObjectForm(store: SettingsStore.demo(), kind: kind,
                    problems: ["form": repo + " " + model + " " + reason]), look: look,
                    offeredWidth: Size.modalWidth - 2 * Space.xxl)
            }
        }
    }

    private func assertRender<V: View>(_ view: V, look: Look, offeredWidth: CGFloat,
                                       offeredHeight: CGFloat? = nil) throws {
        let size = HouseRender.fittingSize(of: view, width: offeredWidth, height: offeredHeight)
        #expect(size.width <= offeredWidth + tolerance && size.width <= width + tolerance)
        #expect(size.height > 0 && size.height.isFinite)
        let png = try HouseRender.png(view, look: look, scale: 1, now: DemoStore.now,
                                      width: offeredWidth, height: offeredHeight)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide <= Int(width) && bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        // A flexible proposal, rather than an imposed exact-width frame, lets a
        // root with an oversized minimum report the width it actually requires.
        let flexible = HouseRender.fittingSize(of: view.frame(maxWidth: offeredWidth))
        #expect(flexible.width <= offeredWidth + tolerance, "Horizontal overflow: \(look), \(flexible)")
    }
}
