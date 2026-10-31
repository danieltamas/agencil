import Foundation

public enum SynapseEvent: Equatable, Sendable {
    case seatStarted(String)
    case claim(id: String, seat: String)
    case rebuttal(id: String, from: String, to: String)
    case agreement(id: String, between: String, and: String)
    case verdict(String, minority: [String])
}

public enum BurstKind: String, Equatable, Sendable { case spark, chord, thicken, retract, fill, fade }

/// One animation to start: what, between which nodes, and for how long. Never longer than 1.2 s (docs/DESIGN.md).
public struct Burst: Equatable, Sendable {
    public let key: String
    public let kind: BurstKind
    public let from: String?
    public let to: String?
    public let duration: Double

    public init(key: String, kind: BurstKind, from: String?, to: String?, duration: Double) {
        self.key = key
        self.kind = kind
        self.from = from
        self.to = to
        self.duration = duration
    }
}

/// Decides what animates: one burst per event, once. Pure, so "every claim sparks exactly once" needs no layer.
public struct SynapseScript: Sendable {
    public static let core = "core"
    private static let fadeSeconds = 0.2

    private let reduceMotion: Bool
    private var seen: Set<String> = []
    public private(set) var minorityThreads: [String] = []

    public init(reduceMotion: Bool = false) { self.reduceMotion = reduceMotion }

    public mutating func feed(_ events: [SynapseEvent]) -> [Burst] {
        var bursts: [Burst] = []
        for event in events {
            for burst in plan(event) { bursts.append(shaped(burst)) }
        }
        return bursts
    }

    private mutating func plan(_ event: SynapseEvent) -> [Burst] {
        switch event {
        case .seatStarted:
            return []
        case .claim(let id, let seat):
            guard seen.insert("spark:\(id)").inserted else { return [] }
            return [Burst(key: "spark:\(id)", kind: .spark, from: seat, to: Self.core, duration: 0.6)]
        case .rebuttal(let id, let from, let to):
            guard seen.insert("chord:\(id)").inserted else { return [] }
            return [Burst(key: "chord:\(id)", kind: .chord, from: from, to: to, duration: 0.6)]
        case .agreement(let id, let first, let second):
            guard seen.insert("thicken:\(id)").inserted else { return [] }
            return [Burst(key: "thicken:\(id)", kind: .thicken, from: first, to: second, duration: 0.4)]
        case .verdict(let verdict, let minority):
            guard seen.insert("verdict").inserted else { return [] }
            minorityThreads = Array(Set(minority)).sorted()
            return [Burst(key: "retract", kind: .retract, from: nil, to: Self.core, duration: 0.8),
                    Burst(key: "fill:\(verdict)", kind: .fill, from: Self.core, to: nil, duration: 1.2)]
        }
    }

    /// Reduce Motion replaces travel and growth with a short cross-fade of the same thing.
    private func shaped(_ burst: Burst) -> Burst {
        guard reduceMotion else { return burst }
        return Burst(key: "fade:\(burst.key)", kind: .fade, from: burst.from, to: burst.to, duration: Self.fadeSeconds)
    }
}

public enum MenuBarMode: Equatable, Sendable { case template, animating(fps: Int), badge }

/// When the menu bar glyph may move. It is always on screen, so it has its own rules (docs/DESIGN.md "Pause and reduce").
public enum MenuBarPolicy {
    public static let frameCount = 14
    public static let fps = 8
    /// The cycle plays once, then rests on the template frame for 26 ticks, so the glyph moves 14 of every 40 ticks.
    public static let cycleTicks = frameCount + 26

    public static func mode(live: Bool, screenAsleep: Bool, locked: Bool, reduceMotion: Bool) -> MenuBarMode {
        guard live, !screenAsleep, !locked else { return .template }
        return reduceMotion ? .badge : .animating(fps: fps)
    }

    public static func frame(tick: Int) -> Int {
        let remainder = tick % frameCount
        return remainder < 0 ? remainder + frameCount : remainder
    }
}
