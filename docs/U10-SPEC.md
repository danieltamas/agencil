# U10 contract: the visual layer

`docs/DESIGN.md` "Visual layer" owns the look and the CPU budgets. This file fixes the testable surface: a pure
animation script in `AgencilCore`, the Core Animation scene in `Kit/Synapse/`, the menu bar policy and frames, the
backdrop mesh, and `scripts/perf.sh`.

## SynapseScript (AgencilCore, `Sources/AgencilCore/Visual/`)

Decides what animates. Pure, so "every claim sparks exactly once" is tested without a layer.

```swift
public enum SynapseEvent: Equatable, Sendable {
    case seatStarted(String)
    case claim(id: String, seat: String)
    case rebuttal(id: String, from: String, to: String)
    case agreement(id: String, between: String, and: String)
    case verdict(String, minority: [String])      // "PASS", "BLOCK" or "INCOMPLETE"
}

public enum BurstKind: String, Equatable, Sendable { case spark, chord, thicken, retract, fill, fade }

public struct Burst: Equatable, Sendable {
    public let key: String        // "spark:<claim id>", "chord:<id>", "thicken:<id>", "retract", "fill:<verdict>", "fade:<event key>"
    public let kind: BurstKind
    public let from: String?      // a seat name, or "core"
    public let to: String?
    public let duration: Double   // seconds
}

public struct SynapseScript: Sendable {
    public init(reduceMotion: Bool = false)
    public mutating func feed(_ events: [SynapseEvent]) -> [Burst]
}
```

- `claim` gives one `spark` from the seat to `"core"`, 0.6 s. `rebuttal` gives one `chord` between the two seats
  (0.6 s). `agreement` gives one `thicken` (0.4 s). `verdict` gives one `retract` (0.8 s, every chord into the core)
  then one `fill` (key `fill:<verdict>`, at most 1.2 s). `seatStarted` gives no burst (the breath is a layer
  animation, not a burst).
- Idempotent: an event whose key was already fed gives no burst, in this call or a later one. 40 claims fed
  in any chunking, with repeats, give 40 sparks, one per claim id, in feed order.
- Every duration is at most 1.2 s.
- `reduceMotion: true`: every burst has kind `.fade` and duration 0.2, key `fade:<the key it replaces>`, and nothing
  else changes (still one burst per event, still idempotent).
- A `verdict` with a non-empty `minority` also keeps one `thread` per minority seat, reported by
  `script.minorityThreads: [String]` (sorted seat names). It is state, not a burst.

## MenuBarPolicy (AgencilCore)

```swift
public enum MenuBarMode: Equatable, Sendable { case template, animating(fps: Int), badge }
public enum MenuBarPolicy {
    public static let frameCount = 14
    public static func mode(live: Bool, screenAsleep: Bool, locked: Bool, reduceMotion: Bool) -> MenuBarMode
    public static func frame(tick: Int) -> Int      // tick % 14, never negative
}
```

- `animating(fps: 8)` only when `live` and not asleep and not locked and not `reduceMotion`.
- `badge` (a static live badge) when `live`, not asleep, not locked and `reduceMotion`.
- `template` in every other case, including asleep or locked while live.

## The scene (Agencil target, `Sources/Agencil/Kit/Synapse/`)

```swift
@MainActor final class RingSceneController {
    let layer: CALayer
    init(seats: [String], reduceMotion: Bool, visible: Bool)
    func play(_ events: [SynapseEvent])
    func setVisible(_ visible: Bool)
    func setLive(_ live: Bool)
    private(set) var sparkLog: [String]        // claim ids whose spark was started, in order
    func showFinalFrame()                       // the end state, no animation
}

enum SynapseProbe {
    static func animationCount(in layer: CALayer?) -> Int        // CAAnimations in the layer tree, recursive
    static func animatedKeyPaths(in layer: CALayer?) -> Set<String>
}

struct CouncilRingView: View {
    init(seats: [String], events: [SynapseEvent], live: Bool, reduceMotion: Bool = false)
}
```

- The scene is `CAShapeLayer`, `CAGradientLayer` and `CAReplicatorLayer` only; no SwiftUI animation API.
- Hidden (`visible == false`, or `panelVisible` false in the view): no `CAAnimation` anywhere in `layer`'s tree,
  also after `play` and `setLive(true)`. Events played while hidden are marked seen (so they do not replay on
  show) but start nothing and do not enter `sparkLog`.
- Visible and live: the slow breath (4 s period) runs as a layer animation on each live node. Not live: no breath.
- Visible: `play` starts each claim's spark once; `sparkLog` has every claim id exactly once however the same
  events are delivered again. A sitting of 5 seats and 40 claims gives `sparkLog.count == 40`, all distinct.
- `reduceMotion`: `animatedKeyPaths` is a subset of `["opacity"]` (cross-fades only), also while live.
- `showFinalFrame()` and the view under `stillImage` draw the end state: all chords retracted, the core filled with
  the verdict hue (PASS `Theme.ok`, BLOCK `Theme.crit`, INCOMPLETE `Theme.warn`; none yet: unfilled), the minority
  threads in `accent2`. Two histories that reach the same final state render the same PNG bytes.

## Menu bar frames and mesh

- `Brand/menubar-frames/1.svg` ... `14.svg`: `viewBox="0 0 36 36"`, black on transparent, built from the glyph's
  geometry in `Brand/icon-menubar.svg`; the nodes light in turn (a lit node is drawn filled, an unlit one as a ring),
  and a spark dot sits on one synapse. Every frame differs from every other.
- `scripts/render-icons.sh <out>` also writes `<out>/MenuBarFrames/<n>.pdf` (14 files) and
  `<out>/mesh.png` (from `Brand/mesh.svg`, 2x panel size). Two runs give identical bytes.
- `Brand/mesh.svg`: a sparse field of nodes and curved links, no vendor mark.
- `MeshTexture.opacity == 0.04` and `MeshTexture.visible(in: Look) == (look == .agencil)` (Agencil target,
  `Kit/Synapse/`). The texture is a still image, never animated.

## scripts/perf.sh

- `scripts/perf.sh --scenarios` prints `closed`, `open`, `live`, `menubar`, one per line.
- `scripts/perf.sh --verdict <scenario> <mean-cpu-percent>` exits 0 when the mean is under the budget and 1 when it is
  not (or the scenario or number is unknown, or the number is negative): budgets `closed` 0.3, `open` 1, `live` 6,
  `menubar` 1.5. The comparison is strict: a mean equal to the budget fails.
- `scripts/perf.sh` with no argument builds release, runs each scenario (30 s warm-up, then `ps -o %cpu= -p <pid>`
  once a second for 60 s), prints the Mac model, the per-scenario mean and the verdict, and exits non-zero when any
  scenario fails. The app takes the scenario from `AGENCIL_PERF=<scenario>`, uses a stub feed (no broker) and, for
  `open` and `live`, shows the panel in a window. `live` feeds a 5-seat stub sitting emitting one claim every 5 s.

## Acceptance

1. `SynapseScript`: one spark per claim, idempotent across repeats and chunkings, durations at most 1.2 s, the
   verdict gives `retract` then `fill`, reduce motion gives only 0.2 s fades, minority threads kept.
2. `MenuBarPolicy`: the mode table above for all 16 input combinations; `frame(tick:)` wraps at 14.
3. Hidden scene: zero `CAAnimation`; visible live scene: a breath (non-empty keypaths); reduced: only `opacity`.
4. 5 seats and 40 claims: `sparkLog` has 40 distinct ids, also when events are delivered twice.
5. Final-frame renders of two different histories are byte-identical; a PASS render differs from the no-verdict render.
6. Frames: 14 SVGs and 14 PDFs, pairwise different, deterministic render; mesh present; `MeshTexture` constants.
7. `perf.sh --scenarios` and `--verdict` behave as above; a real run is recorded in the unit's report.

## Review follow-ups (accepted limits)

Fixed after the cross-vendor review: a verdict stops the breath, the launch state of sleep and lock is read (not
assumed awake), the template restore goes through the status button, `AGENCIL_PERF` needs `--perf` as well, and
`perf.sh` kills its scenario process on exit and compares the unrounded mean.

Measured on an Apple M1 Max (CPU time over 60 to 80 s, machine otherwise loaded): closed 0.00%, open 0.00%, live
0.04%, menubar 1.05% (a continuous 8 fps loop measured 2.6%, so the cycle plays once and rests 3.25 s).

Carried forward, with the reason:
- The ring gets claims, rebuttals and verdicts only from `feedRing`; the broker's panel read carries none yet. U11
  (outcomes) adds the sitting event feed, with a sitting id, a retention limit and a reset.
- Reduce Motion is read when the scene is built; toggling it with the panel open applies on the next panel open.
- The status button is found once; if the status item is rebuilt the glyph falls back to the label image.
- WindowServer CPU is not reported separately by `perf.sh`.
