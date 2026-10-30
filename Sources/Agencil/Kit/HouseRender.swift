import AppKit
import SwiftUI

/// Draws a view offscreen, the way the screenshots and the layout tests need it: an `NSHostingView` in a window
/// that is never shown, then `cacheDisplay`. Not `ImageRenderer`, which draws placeholders for text fields.
/// Nothing reaches the screen, so no capture permission is asked.
@MainActor
enum HouseRender {
    /// The size the view takes when offered `width` (nil: its ideal width) and `height` (nil: its ideal height).
    static func fittingSize<V: View>(of view: V, width: CGFloat? = nil, height: CGFloat? = nil) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)))
        return host.fittingSize
    }

    /// PNG bytes of the view in `look`, fixed clock and no appear animation, so two runs give identical bytes.
    /// The saved look is neither used nor changed.
    static func png<V: View>(_ view: V, look: Look = .agencil, scale: CGFloat = 2, now: Date = Date(timeIntervalSince1970: 0),
                             width: CGFloat? = nil, height: CGFloat? = nil) throws -> Data {
        let previous = Appearance.shared.look
        Appearance.shared.look = look
        defer { Appearance.shared.look = previous }
        let root = view.frame(width: width, height: height).houseScheme()
            .environment(\.stillImage, true).environment(\.demoNow, now)
        let host = NSHostingView(rootView: root)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        let size = host.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    static func write<V: View>(_ view: V, to url: URL, look: Look = .agencil, scale: CGFloat = 2,
                               width: CGFloat? = nil, height: CGFloat? = nil) throws {
        try png(view, look: look, scale: scale, width: width, height: height).write(to: url, options: .atomic)
    }
}
