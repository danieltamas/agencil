import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

@Suite(.serialized) @MainActor struct U29SynthesisLayoutTests {
    // A9: render the actual detail in the actual panel in every look. The
    // broker reader is external I/O; layout and presentation remain real.
    @Test func longSynthesisFitsPanelWithoutHorizontalScrolling() async throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let markdown = "## " + String(repeating: "A long heading for harbor checkout readiness ", count: 12) +
            "\n\n" + (1...30).map { "- Review item \($0) with **care** and `context`." }.joined(separator: "\n") +
            "\n\n```swift\n" + String(repeating: "wide_code_identifier_", count: 100) + "\n```"
        let store = PanelStore(data: try u29PanelData())
        store.detailReader = { _ in u29DetailJSON(summary: markdown) }
        store.open(sitting: "sit_harbor")
        let deadline = ContinuousClock.now + .seconds(30)
        while store.detail?.loading == true {
            guard ContinuousClock.now < deadline else { throw U29LayoutFailure() }
            await Task.yield()
        }
        #expect(store.detail?.synthesis?.markdown == markdown)
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
                    #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5,
                            "Horizontal overflow in \(look)")
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

private struct U29LayoutFailure: Error {}
