import AgencilCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Agencil

/* Invented U28 production names (all other names already exist in U27):
 PanelStore.attachImage(_ data: Data): synchronous store action from B8.
 PanelStore.attachmentsRoot: URL, injectable home directory; images go in its
 attachments child, never the real home in these tests.
 Wake delivery uses existing brokerRequest, not a new API: the actual store sends
 op wake, caller owner, wait_seconds 0 and compose.files to this external transport
 stub. Broker-to-seat delivery is covered by U28ImageAcceptanceTests using U25Rig.
 */
@Suite(.serialized) @MainActor
struct U28PasteAcceptanceTests {
    private func pixels() throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<2 {
            for x in 0..<2 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = 255
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
                bytes[offset + 3] = 255
            }
        }
        return bitmap
    }

    private func png() throws -> Data {
        try #require(pixels().representation(using: .png, properties: [:]))
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("u28-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configured(_ root: URL, wire: U28PasteWire = U28PasteWire()) async throws -> PanelStore {
        let store = PanelStore(data: DemoPanel.data)
        store.attachmentsRoot = root
        store.brokerRequest = { request in try wire.send(request) }
        store.detailReader = { _ in ["state": "running", "rounds": []] }
        try await guarded { await store.newSitting() }
        try #require(store.compose != nil)
        store.compose?.council = "panel"
        store.compose?.question = "Inspect harbor checkout"
        return store
    }

    private func contents(_ root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("attachments")
        if !FileManager.default.fileExists(atPath: directory.path) { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    // B8: inspect the actual bytes and filesystem permissions for both formats.
    @Test(arguments: ["png", "tiff"])
    func pastedImageIsPrivatePNGUnderAttachmentsRoot(format: String) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await configured(root)
        let input = try format == "png" ? png() : #require(pixels().tiffRepresentation)
        store.attachImage(input)
        let paths = try #require(store.compose?.files)
        try #require(paths.count == 1)
        let file = URL(fileURLWithPath: paths[0])
        #expect(file.deletingLastPathComponent() == root.appendingPathComponent("attachments"))
        #expect(file.pathExtension == "png")
        #expect(UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil)
        let data = try Data(contentsOf: file)
        #expect(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 2 && decoded.pixelsHigh == 2)
        let color = try #require(decoded.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.8
            && color.greenComponent < 0.3
            && color.blueComponent < 0.3)
        for (url, mode) in [(file, 0o600), (file.deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
        #expect(try contents(root).count == 1)
    }

    // B8: refusal must not leave an orphan file or change the draft.
    @Test func nonImageDataSetsProblemAndAddsNothing() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await configured(root)
        let before = store.compose
        store.attachImage(Data("not an image".utf8))
        #expect(store.compose == before)
        #expect(store.composeProblem?.isEmpty == false)
        #expect(try contents(root).isEmpty)
    }

    // B8: mixed picked and pasted files share the same eight-file limit.
    @Test(arguments: [0, 1])
    func ninthAttachmentIsRefusedWithoutWritingAnotherImage(pickedCount: Int) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await configured(root)
        if pickedCount == 1 { store.attachFiles([root.appendingPathComponent("picked.txt").path]) }
        for _ in pickedCount..<8 { store.attachImage(try png()) }
        let before = try #require(store.compose?.files)
        #expect(before.count == 8)
        #expect(Set(before).count == 8)
        let files = try contents(root)
        store.attachImage(try png())
        #expect(store.compose?.files == before)
        #expect(store.composeProblem?.isEmpty == false)
        #expect(Set(try contents(root)) == Set(files))
    }

    // B8.
    @Test func detachDeletesOnlyThePastedFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await configured(root)
        store.attachImage(try png())
        let path = try #require(store.compose?.files.first)
        store.detachFile(path)
        #expect(store.compose?.files.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // B8: a picked PNG in the same directory is still not owned by the draft.
    @Test func closeDeletesAllPastedImagesAndPreservesPickedFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await configured(root)
        store.attachImage(try png())
        store.attachImage(try png())
        let pasted = try #require(store.compose?.files)
        let picked = root.appendingPathComponent("attachments/picked.png")
        let bytes = try png()
        try bytes.write(to: picked)
        store.attachFiles([picked.path])
        store.closeCompose()
        #expect(store.compose == nil)
        for path in pasted { #expect(!FileManager.default.fileExists(atPath: path)) }
        #expect(try Data(contentsOf: picked) == bytes)
    }

    // B8: external transport reads bytes before acknowledging; after refusal
    // the exact same draft and files remain available for retry.
    @Test(arguments: [true, false])
    func startCleansPastedFilesOnlyAfterSuccess(success: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = U28PasteWire()
        wire.refuse = !success
        let store = try await configured(root, wire: wire)
        store.attachImage(try png())
        store.attachImage(try png())
        let paths = try #require(store.compose?.files)
        let bytes = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let before = store.compose
        try await guarded { await store.startSitting() }
        #expect(wire.wakes.count == 1)
        let request = try #require(wire.wakes.first)
        #expect(request["op"] as? String == "wake")
        #expect(request["caller"] as? String == "owner")
        #expect(request["wait_seconds"] as? Int == 0)
        #expect(request["files"] as? [String] == paths)
        #expect(wire.bytes == bytes)
        for path in paths { #expect(FileManager.default.fileExists(atPath: path) == !success) }
        if success {
            #expect(store.compose == nil)
            #expect(store.detail?.id == "s-image")
        } else {
            #expect(store.compose == before)
            #expect(store.composeProblem == "refused: image council unavailable")
        }
    }

    // B9: match U27 A10's real-panel render and horizontal scroll checks.
    @Test func eightPastedImagesAndLongQuestionFitEveryLook() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = Appearance.shared.look
        defer { Appearance.shared.look = previous }
        let store = try await configured(root)
        for _ in 0..<8 { store.attachImage(try png()) }
        #expect(store.compose?.files.count == 8)
        store.compose?.question = String(repeating: "Review harbor checkout and its boundary cases. ", count: 120)
        for look in Look.allCases {
            Appearance.shared.look = look
            let view = PanelView(store: store, tab: "sittings")
            let size = HouseRender.fittingSize(of: view)
            #expect(abs(size.width - Size.panelWidth) <= 0.5)
            #expect(size.height > 0 && size.height <= Size.panelMaxHeight + 0.5)
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
                if let document = scroll.documentView {
                    #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5)
                }
            }
            let bitmap = try #require(NSBitmapImageRep(data: HouseRender.png(view, look: look, scale: 1)))
            #expect(bitmap.pixelsWide == Int(Size.panelWidth))
            withExtendedLifetime(window) {}
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func guarded(_ action: @escaping @MainActor () async -> Void) async throws {
        let completion = U28PasteCompletion()
        let task = Task { await action(); completion.done = true }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        while !completion.done {
            guard ContinuousClock.now < deadline else { throw U28PasteFailure() }
            await Task.yield()
        }
    }
}

private struct U28PasteFailure: Error {}
@MainActor private final class U28PasteCompletion { var done = false }
@MainActor private final class U28PasteWire {
    var refuse = false
    var wakes: [[String: Any]] = []
    var bytes: [Data] = []
    func send(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "councils": return ["councils": [["name": "panel"]]]
        case "wake":
            wakes.append(request)
            bytes = try (request["files"] as? [String] ?? []).map {
                try Data(contentsOf: URL(fileURLWithPath: $0))
            }
            if refuse { throw PanelClient.Refused(message: "refused: image council unavailable") }
            return ["sitting": "s-image", "state": "running"]
        default: throw U28PasteFailure()
        }
    }
}
