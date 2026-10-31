import AgencilCore
import AppKit
import SwiftUI

/// The menu bar glyph: the 14-frame synapse cycle, drawn from pre-rendered template PDFs, never per tick
/// (docs/DESIGN.md "Scenes" 4). It animates only while something is live, at 8 fps, and stops while the screen is
/// asleep or locked. With Reduce Motion it shows a static live badge instead.
@MainActor @Observable final class MenuBarGlyphModel {
    private(set) var image: NSImage
    private(set) var mode: MenuBarMode = .template

    @ObservationIgnored private let frames: [NSImage]
    @ObservationIgnored private var live = false
    @ObservationIgnored private var asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    @ObservationIgnored private var locked = MenuBarGlyphModel.sessionIsLocked
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var button: NSStatusBarButton?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        frames = Self.loadFrames()
        image = frames.first ?? Self.fallback
        watchSystem()
    }

    func setLive(_ live: Bool) {
        self.live = live
        refresh()
    }

    private func refresh() {
        let next = MenuBarPolicy.mode(live: live, screenAsleep: asleep, locked: locked,
                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard next != mode else { return }
        mode = next
        timer?.invalidate()
        timer = nil
        switch next {
        case .template:
            image = frames.first ?? Self.fallback
            button?.image = image
        case .badge:
            image = Self.badged(frames.first ?? Self.fallback)
            button?.image = image
        case .animating(let fps):
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Double(fps), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance() }
            }
        }
    }

    /// One 14-frame cycle, then a rest on the template frame: a burst, not a loop (docs/DESIGN.md "Visual layer").
    private func advance() {
        tick += 1
        guard !frames.isEmpty else { return }
        let phase = tick % MenuBarPolicy.cycleTicks
        guard phase <= MenuBarPolicy.frameCount else { return }
        let next = frames[(phase == MenuBarPolicy.frameCount ? 0 : phase) % frames.count]
        if button == nil { button = Self.statusButton() }
        if let button { button.image = next } else { image = next }
    }

    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, (MenuBarGlyphModel) -> Void)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, { $0.asleep = true }),
            (workspace, NSWorkspace.screensDidWakeNotification, { $0.asleep = false }),
            (workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, { _ in }),
            (distributed, Notification.Name("com.apple.screenIsLocked"), { $0.locked = true }),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), { $0.locked = false }),
        ]
        for (center, name, apply) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.refresh()
                }
            }
            observers.append((center, token))
        }
    }

    /// The state at launch, so a launch while the screen is locked does not start moving.
    private static var sessionIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: images

    private static var fallback: NSImage {
        let image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Agencil") ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// The frames ship in the app's Resources; from a build folder they are read from `Support/`.
    private static func loadFrames() -> [NSImage] {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("MenuBarFrames")
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Support/MenuBarFrames")
        guard let directory = [bundled, local].compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("1.pdf").path)
        }) else { return [] }
        return (1...MenuBarPolicy.frameCount).compactMap { index in
            guard let image = NSImage(contentsOf: directory.appendingPathComponent("\(index).pdf")) else { return nil }
            return rasterized(image)
        }
    }

    /// A PDF is parsed and drawn again on every use; a bitmap made once costs nothing per tick.
    private static func rasterized(_ pdf: NSImage) -> NSImage? {
        let side = Int(Size.menuBarGlyph) * 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        pdf.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: Size.menuBarGlyph, height: Size.menuBarGlyph))
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    private static func badged(_ base: NSImage) -> NSImage {
        let size = base.size == .zero ? NSSize(width: Size.menuBarGlyph, height: Size.menuBarGlyph) : base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - rect.width / 4, y: rect.maxY - rect.height / 4,
                                        width: rect.width / 4, height: rect.height / 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The label of the `MenuBarExtra`.
struct MenuBarGlyph: View {
    let model: MenuBarGlyphModel
    let live: Bool

    var body: some View {
        Image(nsImage: model.image)
            .onChange(of: live, initial: true) { model.setLive(live) }
    }
}

extension MenuBarGlyphModel {
    /// The status item's own button, found once. Setting its image directly skips the SwiftUI scene update a label
    /// change costs, which at 8 fps is most of the menu bar budget.
    static func statusButton() -> NSStatusBarButton? {
        func search(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap(search).first
        }
        return NSApp.windows.lazy.compactMap { window in window.contentView.flatMap(search) }.first
    }
}
