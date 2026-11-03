import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

/* U27 A8-A10: expected new production names and external I/O seam.
 SittingDraft: Equatable value with mutable String fields council, kind, question,
 repo, diff, and [String] files; defaults empty except kind = "question".
 PanelStore.compose: SittingDraft?; nil means compose is not open.
 PanelStore.newSitting() async loads configured councils through op "councils"
 (reply data {councils:[{name:"panel"}]}), then opens a fresh draft.
 PanelStore.canStartSitting: Bool drives the actual Start button's disabled state.
 PanelStore.startSitting() async is the specified store action.
 PanelStore.brokerRequest: (@MainActor ([String:Any]) async throws -> [String:Any])?
 is an injected PanelClient transport boundary: receives the complete wire request
 including op/caller; returns the decoded data object, or throws PanelClient.Refused.
 Only external broker I/O is faked; validation, in-flight state, navigation and views
 must use the real store. Existing detailReader supplies external detail I/O.
 PanelView(store:tab:) renders compose when compose != nil and uses the existing
 detail page after success. A source guard checks the Start validation binding;
 offscreen hosting does not expose the button through the accessibility tree.
 */
@Suite(.serialized) @MainActor
struct U27ComposeAcceptanceTests {
    private func configured(_ wire: U27PanelWire) async throws -> PanelStore {
        let store = PanelStore(data: DemoPanel.data)
        store.brokerRequest = { request in try await wire.send(request) }
        store.detailReader = { _ in ["state": "running", "rounds": []] }
        try await guarded { await store.newSitting() }
        try #require(store.compose != nil)
        store.compose?.council = "panel"
        store.compose?.question = "Inspect harbor checkout"
        store.compose?.kind = "design"
        store.compose?.files = ["/tmp/harbor.txt", "/tmp/lumen.txt"]
        return store
    }

    // A8: the held transport proves overlap without a timing threshold.
    @Test func startSendsOwnerWakeOnceDuringOverlapAndOpensReturnedDetail() async throws {
        let wire = U27PanelWire()
        wire.holdFirstWake = true
        let store = try await configured(wire)
        let completion = U27Completion()
        let first = Task { await store.startSitting(); completion.done = true }
        defer { wire.release(); first.cancel() }
        try await wait { wire.wakes.count == 1 }
        #expect(!completion.done, "The first request is still held at the external boundary")
        try await guarded { await store.startSitting() }
        #expect(wire.wakes.count == 1)
        let request = try #require(wire.wakes.first)
        #expect(request["op"] as? String == "wake")
        #expect(request["caller"] as? String == "owner")
        #expect(request["wait_seconds"] as? Int == 0)
        #expect(request["council"] as? String == "panel")
        #expect(request["change_kind"] as? String == "design")
        #expect(request["question"] as? String == "Inspect harbor checkout")
        #expect(request["files"] as? [String] == ["/tmp/harbor.txt", "/tmp/lumen.txt"])
        wire.release()
        try await wait { completion.done }
        #expect(wire.wakes.count == 1)
        #expect(store.compose == nil)
        #expect(store.detail?.id == "s-new")
        #expect(store.detail?.kind == .sitting)
    }

    // A8: code-specific fields cross the same boundary.
    @Test func codeStartSendsRepoAndDiff() async throws {
        let wire = U27PanelWire()
        let store = try await configured(wire)
        store.compose?.kind = "code"
        store.compose?.repo = "/tmp/harbor/checkout"
        store.compose?.diff = "main..HEAD"
        try await guarded { await store.startSitting() }
        let request = try #require(wire.wakes.first)
        #expect(wire.wakes.count == 1)
        #expect(request["repo"] as? String == "/tmp/harbor/checkout")
        #expect(request["diff"] as? String == "main..HEAD")
        #expect(request["change_kind"] as? String == "code")
    }

    // A8: retain every field, including code fields and attachments, on refusal.
    @Test func refusalKeepsDraftAndDisplaysExactBrokerProblem() async throws {
        let wire = U27PanelWire()
        wire.refusal = "refused: local-only council cannot use remote seat"
        let store = try await configured(wire)
        store.compose?.kind = "code"
        store.compose?.repo = "/tmp/harbor/checkout"
        store.compose?.diff = "main..HEAD"
        let before = try #require(store.compose)
        try await guarded { await store.startSitting() }
        #expect(store.compose == before)
        #expect(store.problem == wire.refusal)
        #expect(store.detail == nil)
        #expect(wire.wakes.count == 1)
        #expect(store.canStartSitting, "A refusal must leave the form retryable")
    }

    // A9: independently exercise each missing requirement and valid controls.
    @Test(arguments: ["question", "council", "repo", "diff"])
    func cannotStartForEachMissingRequiredField(missing: String) async throws {
        let store = try await configured(U27PanelWire())
        store.compose?.kind = "code"
        store.compose?.repo = "/tmp/harbor/checkout"
        store.compose?.diff = "main..HEAD"
        #expect(store.canStartSitting)
        switch missing {
        case "question": store.compose?.question = " \n\t "
        case "council": store.compose?.council = ""
        case "repo": store.compose?.repo = ""
        default: store.compose?.diff = ""
        }
        #expect(!store.canStartSitting)
    }

    // A9 control: repo and diff are required only for code.
    @Test(arguments: ["question", "design", "plan", "docs", "other"])
    func nonCodeKindsCanStartWithoutRepoOrDiff(kind: String) async throws {
        let store = try await configured(U27PanelWire())
        store.compose?.kind = kind
        store.compose?.repo = ""
        store.compose?.diff = ""
        #expect(store.canStartSitting)
    }

    // A9: scan the real control, so store validation cannot become detached from Start.
    @Test func startButtonDisabledStateUsesStoreValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Agencil/Views/Panel/ComposeView.swift"), encoding: .utf8)
        // Match the complete argument list, including the in-flight disable condition.
        // Tokens ignore comments and whitespace, as in the existing press guards.
        let tokens = GuardScanner.tokens(source).map(\.text)
        let control = GuardScanner.tokens("""
            PillButton(title: running ? "Starting..." : "Start", symbol: "arrow.up.right", disabled: !store.canStartSitting || running, action: press)
            """).map(\.text)
        #expect(tokens.indices.contains { index in
            tokens[index...].starts(with: control)
        }, "Compose Start must use disabled: !store.canStartSitting || running")
        // The lexer treats strings as opaque; also pin the visible Start label.
        #expect(source.contains("title: running ? \"Starting...\" : \"Start\""))
    }

    // A10: render the real panel at its own fitting size with largest content.
    // Offscreen AX bounds are unavailable. Background pixels alone cannot prove
    // Start visibility, so no bottom-band pixel assertion substitutes for it.
    @Test func composeFitsPanelWithEightChipsAndLongQuestionInEveryLook() async throws {
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let store = try await configured(U27PanelWire())
        store.compose?.question = String(repeating: "Review harbor checkout and its boundary cases. ", count: 120)
        store.compose?.kind = "code"
        store.compose?.repo = "/tmp/" + String(repeating: "harbor-checkout-", count: 12)
        store.compose?.diff = "main.." + String(repeating: "feature-", count: 16)
        store.compose?.files = (1...8).map { "/tmp/" + String(repeating: "attachment-", count: 12) + "\($0).txt" }
        for look in Look.allCases {
            Appearance.shared.look = look
            let view = PanelView(store: store, tab: "sittings")
            let size = HouseRender.fittingSize(of: view)
            #expect(abs(size.width - Size.panelWidth) <= 0.5)
            #expect(size.height > 0 && size.height <= Size.panelMaxHeight + 0.5)
            let host = hostPanel(store)
            for scroll in descendants(host.view).compactMap({ $0 as? NSScrollView }) {
                if let document = scroll.documentView {
                    #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5,
                            "Horizontal overflow in \(look)")
                }
            }
            let bitmap = try #require(NSBitmapImageRep(data: HouseRender.png(view, look: look, scale: 1)))
            #expect(bitmap.pixelsWide == Int(Size.panelWidth))
            withExtendedLifetime(host.window) {}
        }
    }

    private func hostPanel(_ store: PanelStore) -> (view: NSHostingView<PanelView>, window: NSWindow) {
        let view = NSHostingView(rootView: PanelView(store: store, tab: "sittings"))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    // Deadline is solely a hang guard; no assertion depends on elapsed time.
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw U27PanelFailure(message: "30 s hang guard") }
            await Task.yield()
        }
    }

    private func guarded(_ action: @escaping @MainActor () async -> Void) async throws {
        let completion = U27Completion()
        let task = Task { await action(); completion.done = true }
        defer { task.cancel() }
        try await wait { completion.done }
    }
}

private struct U27PanelFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor private final class U27Completion { var done = false }

@MainActor private final class U27PanelWire {
    var wakes: [[String: Any]] = []
    var holdFirstWake = false
    var refusal: String?
    private var pending: CheckedContinuation<Void, Never>?

    func send(_ request: [String: Any]) async throws -> [String: Any] {
        switch request["op"] as? String {
        case "councils": return ["councils": [["name": "panel"]]]
        case "wake":
            wakes.append(request)
            if holdFirstWake && wakes.count == 1 {
                await withCheckedContinuation { pending = $0 }
            }
            if let refusal { throw PanelClient.Refused(message: refusal) }
            return ["sitting": "s-new", "state": "running"]
        default: throw U27PanelFailure(message: "Unexpected broker operation")
        }
    }

    func release() { pending?.resume(); pending = nil }
}
