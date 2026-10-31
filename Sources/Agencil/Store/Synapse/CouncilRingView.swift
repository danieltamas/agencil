import AgencilCore
import AppKit
import SwiftUI

/// The council ring for a view: the scene controller in a layer-backed `NSView`. Pauses with the panel, draws the end
/// state under `stillImage`, and replaces travel with cross-fades under Reduce Motion.
struct CouncilRingView: View {
    let seats: [String]
    let events: [SynapseEvent]
    let live: Bool
    let reduceMotion: Bool
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.stillImage) private var still

    init(seats: [String], events: [SynapseEvent], live: Bool, reduceMotion: Bool = false) {
        self.seats = seats
        self.events = events
        self.live = live
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        RingHost(seats: seats, events: events, live: live && !still, visible: panelVisible && !still, still: still,
                 reduceMotion: reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                 look: Appearance.shared.look)
            .aspectRatio(RingSceneController.canvas.width / RingSceneController.canvas.height, contentMode: .fit)
    }
}

private struct RingHost: NSViewRepresentable {
    let seats: [String]
    let events: [SynapseEvent]
    let live: Bool
    let visible: Bool
    let still: Bool
    let reduceMotion: Bool
    let look: Look

    final class Coordinator {
        let scene: RingSceneController
        var look: Look
        init(scene: RingSceneController, look: Look) {
            self.scene = scene
            self.look = look
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scene: RingSceneController(seats: seats, reduceMotion: reduceMotion, visible: visible), look: look)
    }

    func makeNSView(context: Context) -> RingNSView {
        let view = RingNSView()
        view.wantsLayer = true
        view.scene = context.coordinator.scene.layer
        view.layer?.addSublayer(context.coordinator.scene.layer)
        return view
    }

    func updateNSView(_ view: RingNSView, context: Context) {
        let scene = context.coordinator.scene
        if context.coordinator.look != look {
            context.coordinator.look = look
            scene.restyle()
        }
        scene.setVisible(visible)
        scene.setLive(live)
        scene.play(events)
        if still { scene.showFinalFrame() }
        view.needsLayout = true
    }
}

/// Fits the fixed-size scene canvas into whatever the layout offers.
final class RingNSView: NSView {
    var scene: CALayer?

    override func layout() {
        super.layout()
        guard let scene else { return }
        let scale = min(bounds.width / RingSceneController.canvas.width, bounds.height / RingSceneController.canvas.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.position = CGPoint(x: bounds.midX, y: bounds.midY)
        scene.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }
}
