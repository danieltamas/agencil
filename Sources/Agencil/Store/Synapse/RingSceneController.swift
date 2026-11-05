import AgencilCore
import AppKit
import QuartzCore
import SwiftUI

/// The council ring as Core Animation layers (docs/DESIGN.md "Scenes" 1). Events start bursts; between bursts the
/// scene is static. The only continuous motion is the slow breath on live nodes, and a hidden scene runs nothing.
@MainActor final class RingSceneController {
    static let canvas = CGSize(width: 300, height: 240)
    private static let radius: CGFloat = 80
    private static let nodeRadius: CGFloat = 10
    private static let coreRadius: CGFloat = 16

    let layer = CALayer()
    private(set) var sparkLog: [String] = []

    private let seats: [String]
    private let reduceMotion: Bool
    private var visible: Bool
    private var live = false
    private var script: SynapseScript
    private var chords: [Chord] = []
    private var verdict: String?
    private var minority: [String] = []

    private var nodes: [String: CAShapeLayer] = [:]
    private var chordLayers: [String: CAShapeLayer] = [:]
    private var threadLayers: [CAShapeLayer] = []
    private var transient: [CALayer] = []
    private let synapses = CALayer()
    private let core = CAShapeLayer()
    private let coreFill = CAShapeLayer()

    private struct Chord {
        let key: String
        let from: String
        let to: String
        var thick = false
    }

    init(seats: [String], reduceMotion: Bool, visible: Bool) {
        self.seats = seats
        self.reduceMotion = reduceMotion
        self.visible = visible
        script = SynapseScript(reduceMotion: reduceMotion)
        layer.bounds = CGRect(origin: .zero, size: Self.canvas)
        layer.isGeometryFlipped = true
        build()
        restyle()
    }

    // MARK: control

    func play(_ events: [SynapseEvent]) {
        let bursts = script.feed(events)
        guard !bursts.isEmpty else { return }
        var retiring: [CAShapeLayer] = []
        for burst in bursts { retiring += record(burst) }
        syncLayers()
        if verdict != nil, live {
            live = false
            updateBreath()
        }
        guard visible else { return }
        for burst in bursts { animate(burst, retiring: retiring) }
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if !visible { stopEverything() }
        updateBreath()
    }

    func setLive(_ live: Bool) {
        self.live = live
        updateBreath()
    }

    /// The end state with nothing moving: chords retracted after a verdict, the core filled with its hue.
    func showFinalFrame() {
        stopEverything()
        syncLayers()
    }

    /// Re-reads the theme: a new look recolors the same layers.
    func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, node) in nodes { node.fillColor = cg(Theme.accent); node.strokeColor = nil }
        for layer in synapses.sublayers ?? [] { (layer as? CAShapeLayer)?.strokeColor = cg(Theme.textTertiary, alpha: 0.35) }
        core.fillColor = cg(Theme.canvasLift)
        core.strokeColor = cg(Theme.accent)
        syncLayers()
        CATransaction.commit()
    }

    // MARK: model

    /// Updates what the scene shows after `burst`. Returns the chord layers a retract must animate away.
    private func record(_ burst: Burst) -> [CAShapeLayer] {
        let key = burst.key.hasPrefix("fade:") ? String(burst.key.dropFirst(5)) : burst.key
        if key.hasPrefix("spark:") {
            if visible { sparkLog.append(String(key.dropFirst(6))) }
        } else if key.hasPrefix("chord:"), let from = burst.from, let to = burst.to {
            chords.append(Chord(key: key, from: from, to: to))
        } else if key.hasPrefix("thicken:"), let from = burst.from, let to = burst.to {
            if let index = chords.firstIndex(where: { Set([$0.from, $0.to]) == Set([from, to]) }) { chords[index].thick = true }
            else { chords.append(Chord(key: key, from: from, to: to, thick: true)) }
        } else if key == "retract" {
            chords = []
            guard visible else { return [] }
            let moving = Array(chordLayers.values)
            chordLayers = [:]
            transient += moving
            return moving
        } else if key.hasPrefix("fill:") {
            verdict = String(key.dropFirst(5))
            minority = script.minorityThreads
        }
        return []
    }

    // MARK: layers

    private func build() {
        layer.addSublayer(synapses)
        for seat in seats {
            let synapse = CAShapeLayer()
            synapse.path = synapsePath(from: position(of: seat))
            synapse.fillColor = nil
            synapse.lineWidth = 1.5
            synapses.addSublayer(synapse)
        }
        core.path = circle(at: center, radius: Self.coreRadius)
        core.lineWidth = 2
        layer.addSublayer(core)
        coreFill.path = circle(at: center, radius: Self.coreRadius)
        coreFill.opacity = 0
        layer.addSublayer(coreFill)
        for seat in seats {
            let node = CAShapeLayer()
            node.path = circle(at: position(of: seat), radius: Self.nodeRadius)
            layer.addSublayer(node)
            nodes[seat] = node
        }
    }

    /// Brings the layers in line with the model, without implicit animation.
    private func syncLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let wanted = Set(chords.map(\.key))
        for (key, chordLayer) in chordLayers where !wanted.contains(key) {
            chordLayer.removeFromSuperlayer()
            chordLayers[key] = nil
        }
        for chord in chords {
            let chordLayer = chordLayers[chord.key] ?? makeChord(chord)
            chordLayer.lineWidth = chord.thick ? 3.5 : 1.5
            chordLayer.strokeColor = cg(chord.thick ? Theme.ok : Theme.warn)
        }
        coreFill.fillColor = cg(verdictColor)
        coreFill.opacity = verdict == nil ? 0 : 1
        threadLayers.forEach { $0.removeFromSuperlayer() }
        threadLayers = minority.filter { nodes[$0] != nil }.map { seat in
            let thread = CAShapeLayer()
            thread.path = synapsePath(from: position(of: seat))
            thread.fillColor = nil
            thread.lineWidth = 1.2
            thread.strokeColor = cg(Theme.accent2)
            layer.insertSublayer(thread, below: core)
            return thread
        }
    }

    private func makeChord(_ chord: Chord) -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: position(of: chord.from))
        path.addLine(to: position(of: chord.to))
        let chordLayer = CAShapeLayer()
        chordLayer.path = path
        chordLayer.fillColor = nil
        chordLayer.lineCap = .round
        layer.insertSublayer(chordLayer, below: core)
        chordLayers[chord.key] = chordLayer
        return chordLayer
    }

    // MARK: animation

    private func animate(_ burst: Burst, retiring: [CAShapeLayer]) {
        let key = burst.key.hasPrefix("fade:") ? String(burst.key.dropFirst(5)) : burst.key
        if key.hasPrefix("spark:"), let from = burst.from {
            let spark = CAShapeLayer()
            spark.path = synapsePath(from: position(of: from))
            spark.fillColor = nil
            spark.lineWidth = 2.5
            spark.lineCap = .round
            spark.strokeColor = cg(Theme.accent)
            layer.addSublayer(spark)
            run(travel(burst.duration), on: spark, remove: true)
        } else if key.hasPrefix("chord:"), let chordLayer = chordLayers[key] {
            run(travel(burst.duration), on: chordLayer)
        } else if key.hasPrefix("thicken:"), let index = chords.firstIndex(where: { Set([$0.from, $0.to]) == Set([burst.from ?? "", burst.to ?? ""]) }),
                  let chordLayer = chordLayers[chords[index].key] {
            let grow = reduceMotion ? fade(from: 0.4, to: 1, burst.duration) : basic("lineWidth", from: 1.5, to: 3.5, burst.duration)
            run(grow, on: chordLayer)
        } else if key == "retract" {
            for moving in retiring {
                run(reduceMotion ? fade(from: 1, to: 0, burst.duration) : basic("strokeEnd", from: 1, to: 0, burst.duration), on: moving, remove: true)
            }
        } else if key.hasPrefix("fill:") {
            run(fade(from: 0, to: 1, reduceMotion ? burst.duration : 0.4), on: coreFill)
            if !reduceMotion { ripple() }
        }
    }

    private func travel(_ seconds: Double) -> CAAnimation {
        reduceMotion ? fade(from: 0, to: 1, seconds) : basic("strokeEnd", from: 0, to: 1, seconds)
    }

    private func basic(_ keyPath: String, from: CGFloat, to: CGFloat, _ seconds: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = seconds
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    private func fade(from: CGFloat, to: CGFloat, _ seconds: Double) -> CABasicAnimation {
        basic("opacity", from: from, to: to, seconds)
    }

    private func run(_ animation: CAAnimation, on target: CALayer, remove: Bool = false) {
        if remove { transient.append(target) }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak target] in
            MainActor.assumeIsolated {
                guard remove, let target else { return }
                target.removeFromSuperlayer()
                self?.transient.removeAll { $0 === target }
            }
        }
        target.add(animation, forKey: UUID().uuidString)
        CATransaction.commit()
    }

    private func ripple() {
        let ring = CAShapeLayer()
        ring.path = circle(at: center, radius: Self.coreRadius)
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.strokeColor = cg(verdictColor)
        ring.bounds = layer.bounds
        ring.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        layer.addSublayer(ring)
        let scale = basic("transform.scale", from: 1, to: 2.2, 0.8)
        let group = CAAnimationGroup()
        group.animations = [scale, fade(from: 0.8, to: 0, 0.8)]
        group.duration = 0.8
        run(group, on: ring, remove: true)
    }

    private func updateBreath() {
        for (_, node) in nodes { node.removeAnimation(forKey: "breath") }
        guard visible, live else { return }
        for (_, node) in nodes {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 1
            breath.toValue = 0.55
            breath.duration = 2
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            node.add(breath, forKey: "breath")
        }
    }

    private func stopEverything() {
        Self.removeAnimations(in: layer)
        transient.forEach { $0.removeFromSuperlayer() }
        transient = []
    }

    private static func removeAnimations(in layer: CALayer) {
        layer.removeAllAnimations()
        (layer.sublayers ?? []).forEach(removeAnimations)
    }

    // MARK: geometry and colour

    private var center: CGPoint { CGPoint(x: Self.canvas.width / 2, y: Self.canvas.height / 2) }

    /// Seats sit on a 270 degree ring, open at the bottom.
    private func position(of seat: String) -> CGPoint {
        let index = seats.firstIndex(of: seat) ?? 0
        let steps = max(seats.count - 1, 1)
        let angle = (135 + 270 * Double(index) / Double(steps)) * .pi / 180
        return CGPoint(x: center.x + Self.radius * CGFloat(cos(angle)), y: center.y + Self.radius * CGFloat(sin(angle)))
    }

    private func synapsePath(from point: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point)
        let mid = CGPoint(x: (point.x + center.x) / 2, y: (point.y + center.y) / 2)
        let control = CGPoint(x: mid.x + (center.y - point.y) * 0.2, y: mid.y + (point.x - center.x) * 0.2)
        path.addQuadCurve(to: center, control: control)
        return path
    }

    private func circle(at point: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    private var verdictColor: Color {
        switch verdict {
        case "PASS", "AGREED", "ANSWERED": Theme.ok
        case "BLOCK": Theme.crit
        case "SPLIT": Theme.unknown
        default: Theme.warn
        }
    }

    private func cg(_ color: Color, alpha: CGFloat = 1) -> CGColor {
        alpha == 1 ? NSColor(color).cgColor : NSColor(color).withAlphaComponent(alpha).cgColor
    }
}
