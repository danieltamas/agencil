import AppKit
import SwiftUI

/// A live-state dot. The pulse is a Core Animation layer, so it costs the SwiftUI layout nothing (docs/DESIGN.md).
struct PulseDot: View {
    var color: Color = Theme.ok
    var live = true
    @Environment(\.stillImage) private var still

    var body: some View {
        PulseLayer(color: NSColor(color), live: live && !still)
            .frame(width: 10, height: 10)
    }
}

private struct PulseLayer: NSViewRepresentable {
    let color: NSColor
    let live: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        layer.sublayers = nil
        let dot = CALayer()
        dot.frame = CGRect(x: 2, y: 2, width: 6, height: 6)
        dot.cornerRadius = 3
        dot.backgroundColor = color.cgColor
        layer.addSublayer(dot)
        guard live else { return }
        let ring = CALayer()
        ring.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        ring.cornerRadius = 5
        ring.borderColor = color.cgColor
        ring.borderWidth = 1
        layer.insertSublayer(ring, at: 0)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6
        group.repeatCount = .infinity
        ring.add(group, forKey: "pulse")
    }
}
