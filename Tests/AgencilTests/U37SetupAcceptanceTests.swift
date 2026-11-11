/* API contract
 SetupStore.shouldOpen(values: [String: String]) -> Bool.
 SetupStore.demo(findings: [HarnessFinding]) -> SetupStore is inert, step == .found.
 SetupView.init(store: SetupStore); Size.setupWindow: CGSize.
 HarnessFinding.init(kind:found:version:signedIn:).
 Existing Look.allCases, Appearance.shared.look, HouseRender.fittingSize(of:width:height:),
 HouseRender.png(_:look:scale:now:width:height:), DemoStore.now, Size.control,
 KitGallery.controls (name, view), ChipButton.init(title:action:) remain usable.
 No mutable production state or additional test hooks are assumed.
 */
import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

@Suite(.serialized) @MainActor struct U37SetupAcceptanceTests {
    private let tolerance: CGFloat = 0.5

    // Acceptance 10.
    @Test func launchEligibilityDependsOnHavingNoSeats() {
        #expect(SetupStore.shouldOpen(values: [:]))
        #expect(SetupStore.shouldOpen(values: ["seats": ""]))
        #expect(SetupStore.shouldOpen(values: ["seats": "[]"]))
        #expect(!SetupStore.shouldOpen(values: ["seats":
            #"[{"name":"harbor-review","harness":"codex","model":"gpt-6.1-sol"}]"#]))
    }

    // Acceptance 9: all three finding counts, every Look, the real Setup root.
    @Test func setupWindowRendersAtFixedSizeInEveryLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let findings = [
            HarnessFinding(kind: "claude", found: true, version: "1.0", signedIn: "yes"),
            HarnessFinding(kind: "codex", found: true, version: "1.0", signedIn: "no"),
            HarnessFinding(kind: "opencode", found: true, version: "1.0", signedIn: "unknown"),
            HarnessFinding(kind: "gemini", found: true, version: "1.0", signedIn: "yes"),
            HarnessFinding(kind: "antigravity", found: false, version: nil, signedIn: "unknown")
        ]
        let window = Size.setupWindow
        #expect(window.width > 0 && window.height > 0)
        for look in Look.allCases {
            Appearance.shared.look = look
            for count in [0, 1, 5] {
                let store = SetupStore.demo(findings: Array(findings.prefix(count)))
                #expect(store.step == .found)
                let view = SetupView(store: store)
                let natural = HouseRender.fittingSize(of: view)
                #expect(natural.width <= window.width + tolerance, "Ideal width: \(look), \(count), \(natural)")
                #expect(natural.height <= window.height + tolerance)
                try assertRender(view, look: look, size: window)
            }
        }
    }

    // Acceptance 9: measure the row-control kit as in the panel layout suite.
    @Test func setupRowControlsMeasure28PointsInEveryLook() {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        #expect(Size.control == 28)
        #expect(!KitGallery.controls.isEmpty)
        for look in Look.allCases {
            Appearance.shared.look = look
            for title in ["Recheck", "Create seats", "Create council", "Skip", "Create routes", "Open Settings", "Close"] {
                let size = HouseRender.fittingSize(of: ChipButton(title: title) {})
                #expect(abs(size.height - 28) <= tolerance, "\(look), \(title): \(size)")
            }
            for control in KitGallery.controls {
                let size = HouseRender.fittingSize(of: control.view)
                #expect(abs(size.height - 28) <= tolerance, "\(look), \(control.name): \(size)")
            }
        }
    }

    private func assertRender<V: View>(_ view: V, look: Look, size: CGSize) throws {
        let measured = HouseRender.fittingSize(of: view, width: size.width, height: size.height)
        #expect(abs(measured.width - size.width) <= tolerance)
        #expect(abs(measured.height - size.height) <= tolerance)
        let png = try HouseRender.png(view, look: look, scale: 1, now: DemoStore.now,
                                      width: size.width, height: size.height)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == Int(size.width))
        #expect(bitmap.pixelsHigh == Int(size.height))
        let flexible = HouseRender.fittingSize(of: view.frame(maxWidth: size.width))
        #expect(flexible.width <= size.width + tolerance, "Horizontal overflow: \(look), \(flexible)")
    }
}
