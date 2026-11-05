import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

@Suite(.serialized) @MainActor struct U33PositionsLayoutTests {
    // A13: render the real Positions block, with a maximum-length position,
    // long crux and both chips, in every look at the actual panel width.
    @Test func longPositionAndCruxFitPanelWidth() async throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let position = String(repeating: "p", count: 300)
        let crux = String(repeating: "A measured capacity constraint changes this position. ", count: 19)
        let store = PanelStore(data: try u29PanelData())
        store.detailReader = { _ in u33DetailJSON(position: position, crux: crux) }
        store.open(sitting: "sit_harbor")
        let deadline = ContinuousClock.now + .seconds(30)
        while store.detail?.loading == true {
            guard ContinuousClock.now < deadline else { throw U33LayoutFailure() }
            await Task.yield()
        }
        #expect(store.detail?.positions.count == 2)
        #expect(store.detail?.positions.first?.finalPosition == position)
        for look in Look.allCases {
            Appearance.shared.look = look
            let panel = PanelView(store: store, tab: "sittings")
            let size = HouseRender.fittingSize(of: panel)
            #expect(abs(size.width - Size.panelWidth) <= 0.5, "\(look): \(size)")
            #expect(size.height > 0 && size.height <= Size.panelMaxHeight + 0.5)
            let host = NSHostingView(rootView: panel)
            host.frame.size = size
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
            #expect(!scrolls.isEmpty)
            for scroll in scrolls {
                #expect(!scroll.hasHorizontalScroller, "Horizontal scroller in \(look)")
                if let document = scroll.documentView {
                    #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5, "Overflow in \(look)")
                }
            }
            let bitmap = try #require(NSBitmapImageRep(data: HouseRender.png(panel, look: look, scale: 1)))
            #expect(bitmap.pixelsWide == Int(Size.panelWidth) && bitmap.pixelsHigh > 0)
            withExtendedLifetime(window) {}
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

private struct U33LayoutFailure: Error {}
