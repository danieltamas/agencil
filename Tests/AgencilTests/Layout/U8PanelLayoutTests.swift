import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

/* API contract
 Agencil/Store/PanelStore.swift: @MainActor @Observable final class PanelStore.
 init(data: PanelData?) is an inert snapshot initializer: no timers, broker, network,
 notifications or other side effects. nil is the waiting-before-first-read state.
 static func demo() -> PanelStore uses DemoStore/DemoPanel's synthetic data.
 static func waiting() -> PanelStore is equivalent to init(data: nil).
 Agencil/Views/Panel/PanelView.swift: init(store: PanelStore, tab: String = "threads").
 Tabs are threads/sittings/findings/seats. Rendering never initiates a read.
 The existing ThreadRow(thread:), SittingRow(sitting:), SeatScoreRow(seat:) and
 FindingRow(finding:) DemoPanel initializers remain usable for long-name layout
 fixtures. They may adapt these presentation values to live rows internally.
 No extra production-only testing hooks are required.
 */

@Suite(.serialized) @MainActor struct U8PanelLayoutTests {
    private let tabs = ["threads", "sittings", "findings", "seats"]
    private let tolerance: CGFloat = 0.5

    @Test func everyTabIs404PointsInEveryLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        for look in Look.allCases {
            Appearance.shared.look = look
            for tab in tabs {
                let view = PanelView(store: PanelStore.demo(), tab: tab)
                try assertPanel(view, look: look, label: "demo \(tab)")
            }
        }
    }

    @Test func emptyAndWaitingStatesInEveryTabAndLook() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        for look in Look.allCases {
            Appearance.shared.look = look
            for configured in [false, true] {
                let empty = try PanelData(json: [
                    "configured": configured,
                    "seats": ["total": 0, "up": 0, "thinking": 0, "items": []],
                    "threads": [], "sittings": [], "findings": [],
                    "proposals_pending": 0, "week": ["spend_usd": 0], "live": 0
                ])
                for tab in tabs {
                    try assertPanel(PanelView(store: PanelStore(data: empty), tab: tab),
                                    look: look, label: "empty configured=\(configured) \(tab)")
                }
            }
            for tab in tabs {
                try assertPanel(PanelView(store: PanelStore.waiting(), tab: tab),
                                look: look, label: "waiting \(tab)")
            }
        }
    }

    @Test func rowControlsAre28PointsInEveryLook() {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        // Row actions use the same kit controls as the rendered panel. Cover both
        // destructive and ordinary variants, including the in-flight Stop label.
        let actions = ["Stop", "Stopping...", "Rerun with other seats", "Open report",
                       "Copy verdict JSON", "Confirm", "Dismiss", "Will fix", "Continue in Terminal"]
        for look in Look.allCases {
            Appearance.shared.look = look
            for title in actions {
                let control = ChipButton(title: title, destructive: title == "Stop") {}
                let size = HouseRender.fittingSize(of: control)
                #expect(abs(size.height - 28) <= tolerance, "\(look) \(title): \(size)")
            }
            for control in KitGallery.controls {
                let size = HouseRender.fittingSize(of: control.view)
                #expect(abs(size.height - 28) <= tolerance, "\(look) \(control.name): \(size)")
            }
        }
    }

    @Test func realRowsConstrainLongRepositoryModelAndFailureReason() throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let repo = String(repeating: "harbor/checkout-", count: 5) + "#214"
        let model = String(repeating: "local-model-long-context-", count: 4)
        let reason = String(repeating: "The endpoint closed before the answer was complete. ", count: 4)
        #expect(repo.count >= 48 && model.count >= 60 && reason.count >= 120)
        let width = Size.panelWidth - 2 * Space.panelInset
        for look in Look.allCases {
            Appearance.shared.look = look
            let rows: [AnyView] = [
                AnyView(ThreadRow(thread: DemoPanel.Thread(id: "long-thread", caller: "owner", seat: model,
                    question: repo, state: "failed: " + reason, live: false, failed: true))),
                AnyView(SittingRow(sitting: DemoPanel.Sitting(id: "long-sitting", kind: "Code", hue: 0,
                    target: repo, wokenBy: "owner", state: "INCOMPLETE", seats: 3, elapsed: "2m", cost: "$0.42", live: false))),
                AnyView(SeatScoreRow(seat: DemoPanel.SeatRow(id: "local-seat", model: model, up: false,
                    confirmed: "n=0, too few", coverage: "n=0, too few", cost: "$0", median: "0s", overlap: reason, enough: false))),
                AnyView(FindingRow(finding: DemoPanel.Finding(id: "long-finding", severity: "P1",
                    place: repo + ":120", claim: reason, backers: 2, dissent: 1)))
            ]
            for (index, row) in rows.enumerated() {
                let size = HouseRender.fittingSize(of: row, width: width)
                #expect(size.width <= width + tolerance, "Row \(index) bounds: \(look)")
                #expect(size.height > 0)
                let png = try HouseRender.png(row, look: look, scale: 1, now: DemoStore.now, width: width)
                let bitmap = try #require(NSBitmapImageRep(data: png))
                #expect(bitmap.pixelsWide == Int(width) && bitmap.pixelsHigh > 0)
            }
            // Reasons must show every line; a one-line ellipsis is not a fit.
            let actual = Text(reason).font(.house.meta).detailLines()
            let ideal = Text(reason).font(.house.meta).fixedSize(horizontal: false, vertical: true)
            let measured = HouseRender.fittingSize(of: actual, width: width)
            let complete = HouseRender.fittingSize(of: ideal, width: width)
            #expect(measured.height >= complete.height - tolerance, "Reason truncates: \(look)")
            let shortThread = ThreadRow(thread: DemoPanel.Thread(id: "short-thread", caller: "owner", seat: model,
                question: repo, state: "failed: closed", live: false, failed: true))
            let shortSize = HouseRender.fittingSize(of: shortThread, width: width)
            let longSize = HouseRender.fittingSize(of: rows[0], width: width)
            let oneLine = HouseRender.fittingSize(of: Text("failed: closed").font(.house.meta))
            // Measure the actual row too: testing an unrestricted copy of Text
            // alone would miss a lineLimit(1) hidden inside ThreadRow.
            #expect(longSize.height >= shortSize.height + complete.height - oneLine.height - tolerance,
                    "Thread row hides its failure reason: \(look)")
        }
    }

    private func assertPanel<V: View>(_ view: V, look: Look, label: String) throws {
        // Do not constrain width here: an imposed 404 frame would hide a bad panel.
        let size = HouseRender.fittingSize(of: view)
        #expect(abs(size.width - 404) <= tolerance, "\(label): \(look) \(size)")
        #expect(size.height > 0 && size.height <= Size.panelMaxHeight + tolerance)
        let png = try HouseRender.png(view, look: look, scale: 1, now: DemoStore.now)
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 404 && bitmap.pixelsHigh > 0, "\(label): \(look)")
    }
}
