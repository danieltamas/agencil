import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

@Suite(.serialized) @MainActor struct U31CostsLayoutTests {
    // A9: real settings root plus an unconstrained pane, populated and empty.
    @Test func costsFollowBudgetsAndRenderAtMinimumSizeInEveryLook() async throws {
        let panes = SettingsPane.allCases
        let budgets = try #require(panes.firstIndex(of: .budgets))
        #expect(panes.dropFirst(budgets + 1).first == .costs)
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let width = Size.settingsMin.width - Size.settingsSidebar - 2 * Space.pane
        for empty in [false, true] {
            let store = CostsStore(reader: { day in
                if empty { return ["now": "2030-03-14T23:30:00Z", "rows": [[String: Any]]()] }
                return u31CostsJSON(day: day, longNames: true)
            }, calendar: u31PageCalendar())
            await store.reload()
            if !empty { await store.select(u31PageDate("2030-03-15")) }
            for look in Look.allCases {
                Appearance.shared.look = look
                try render(SettingsView(store: SettingsStore.demo(), pane: .costs), look: look,
                           width: Size.settingsMin.width, height: Size.settingsMin.height)
                for group in CostGroup.allCases {
                    store.group = group
                    try render(CostsPane(store: store, open: { _ in }), look: look, width: width)
                }
            }
        }
    }

    // A9: the complete 30-bar strip must fit the available card interior.
    @Test func thirtyBarsAndShareMetersFitNarrowCardWithoutChangingHeight() throws {
        let width = Size.settingsMin.width - Size.settingsSidebar - 2 * Space.pane - 2 * Space.xl
        var bars: [BarStrip.Bar] = []
        for index in 0..<30 {
            let share: Double = Double(index) / 29
            bars.append(BarStrip.Bar(id: String(index), share: share, today: index == 29,
                                    lit: index == 15, filled: index > 0, help: "Harbor day \(index)"))
        }
        for look in Look.allCases {
            try render(BarStrip(bars: bars, onSelect: { _ in }), look: look, width: width)
            let heights = [0.0, 0.5, 1.0].map {
                HouseRender.fittingSize(of: ShareBar(share: $0), width: width).height
            }
            #expect(heights.allSatisfy { $0 > 0 && abs($0 - heights[0]) <= 0.5 })
        }
    }

    // A9: the existing source guard enforces token-only spacing on the new pane too.
    @Test func costsPaneUsesSpacingTokens() throws {
        let files = try GuardScanner.files(in: SourceGuardTests.root.appendingPathComponent("Sources/Agencil/Views"))
        let costs = files.filter { $0.lastPathComponent == "CostsPane.swift" }
        #expect(costs.count == 1)
        #expect(try GuardScanner.violations(guard: .size, in: costs).isEmpty)
    }

    // A9: identical data and fixed surrounding cards isolate added group-line height.
    @Test func byChipsFitNarrowWidthAndGroupLinesHaveUniformHeight() async throws {
        let store = CostsStore(reader: { _ in
            var rows: [[String: Any]] = []
            let callers: [String] = ["maya", "jonas", "lee"]
            for index in 0..<3 {
                let row: [String: Any] = ["day": "2030-03-15", "project": "harbor/checkout", "seat": "maya",
                 "council": index == 0 ? "harbor" : "lumen", "caller": callers[index],
                 "model": "harbor-model", "calls": 1, "unpriced": 0, "cost": 1]
                rows.append(row)
            }
            return ["now": "2030-03-14T23:30:00Z", "rows": rows]
        }, calendar: u31PageCalendar())
        await store.reload()
        store.range = .today
        let width = Size.settingsMin.width - Size.settingsSidebar - 2 * Space.pane
        for look in Look.allCases {
            var heights: [CGFloat] = []
            for (group, count) in [(CostGroup.seat, 1), (.council, 2), (.caller, 3)] {
                store.group = group
                #expect(store.groupRows.count == count)
                let pane = CostsPane(store: store, open: { _ in })
                heights.append(HouseRender.fittingSize(of: pane, width: width).height)
                // A narrow proposal forces both complete chip sets to wrap.
                try render(pane, look: look, width: width / 2)
            }
            #expect(heights[1] > heights[0])
            #expect(abs((heights[2] - heights[1]) - (heights[1] - heights[0])) <= 0.5)
        }
    }

    private func render<V: View>(_ view: V, look: Look, width: CGFloat, height: CGFloat? = nil) throws {
        let natural = HouseRender.fittingSize(of: view.frame(maxWidth: width))
        #expect(natural.width <= width + 0.5 && natural.height > 0)
        let size = HouseRender.fittingSize(of: view, width: width, height: height)
        #expect(size.width <= width + 0.5 && size.height > 0 && size.height.isFinite)
        let host = NSHostingView(rootView: view)
        host.frame.size = size
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
            #expect(!scroll.hasHorizontalScroller)
            if let document = scroll.documentView {
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5)
            }
        }
        let bitmap = try #require(NSBitmapImageRep(data: HouseRender.png(view, look: look, scale: 1,
            now: DemoStore.now, width: width, height: height)))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsWide <= Int(ceil(width)) && bitmap.pixelsHigh > 0)
        withExtendedLifetime(window) {}
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
