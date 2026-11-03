import Foundation

/// One seat's place in a sitting: the seat that fills it now (a spare may take over), and where it stands.
final class Slot {
    enum Phase: String { case pending, running, answered, failed, abstained, recused, refused }

    var seat: Seat
    var phase: Phase = .pending
    var reason: String?
    /// The latest answer that validated; its vote is the seat's vote.
    var vote: String?
    var round = "blind"
    var thread: String?
    /// Unparsable twice in some round: the seat's claims and vote are out of the verdict.
    var excluded = false
    /// What this round produced, held until the round's barrier stores it.
    var result: RoundResult?
    /// The notes of the latest answer that had any, kept across rounds: a seat that fails a later round still said them.
    var notes: String?

    init(seat: Seat) { self.seat = seat }

    var settled: Bool { ![.pending, .running].contains(phase) }
}

struct RoundResult {
    let seat: Seat
    let started: Date
    var ended = Date()
    var answer: SeatAnswer?
}

/// A sitting while it runs. Threads of its seats share it, so every mutable field is touched under `lock`.
final class SittingRun: @unchecked Sendable {
    let id: String
    let number: Int
    let council: Council
    let config: SeatConfig
    let route: Route
    let caller: String
    let parent: CapabilityRun?
    let snapshot: Snapshot
    let changeKind: String
    let diffRange: String?
    let question: String
    /// Files attached to the question; they travel in every round's prompt as evidence.
    let attached: [(path: String, text: String)]
    /// Images attached to the question: every round hands them to the seats that can see them.
    let images: [AttachedImage]
    let authorVendor: String
    let deadline: Date
    private let lock = NSLock()

    private(set) var slots: [Slot]
    private var spares: [Seat]
    private(set) var round = "blind"
    private(set) var stopped = false
    private(set) var fallbackUsed = false
    private(set) var running = Set<String>()
    private(set) var claims: [StoredClaim] = []
    /// Latest stance of each seat on each claim: claim id, then seat.
    private(set) var stances: [String: [String: (stance: String, why: String)]] = [:]
    var summary: String?
    /// The seat that wrote `summary`, and whether it did so for want of a configured synthesizer.
    var summaryBy: String?
    var summaryFallback = false
    /// The caller asked for a written summary even when the council has no synthesizer.
    var wantsSummary = false
    var synthesizerFailed: Bool?
    /// Vendors the council was convened with, before any spare took a seat over.
    let conveneVendors: Set<String>

    init(id: String, number: Int, council: Council, config: SeatConfig, route: Route, caller: String, parent: CapabilityRun?,
         snapshot: Snapshot, changeKind: String, diffRange: String?, question: String, authorVendor: String, slots: [Slot], spares: [Seat],
         attached: [(path: String, text: String)] = [], images: [AttachedImage] = []) {
        self.id = id; self.number = number; self.council = council; self.config = config; self.route = route
        self.caller = caller; self.parent = parent; self.snapshot = snapshot; self.changeKind = changeKind
        self.diffRange = diffRange; self.question = question; self.authorVendor = authorVendor; self.attached = attached; self.images = images
        self.slots = slots; self.spares = spares
        conveneVendors = Set(slots.filter { $0.phase != .recused }.map(\.seat.vendor))
        deadline = Date().addingTimeInterval(Double(council.deadlineSeconds))
    }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var chain: [String] { parent?.chain ?? [] }

    func setRound(_ name: String) { locked { round = name } }
    func stop() { locked { stopped = true } }
    var isOver: Bool { locked { stopped } || Date() >= deadline }

    func track(_ thread: String, running now: Bool) {
        locked { if now { running.insert(thread) } else { running.remove(thread) } }
    }

    /// The next spare that is not already used; taking it marks the sitting as having used a fallback.
    func takeSpare() -> Seat? {
        locked {
            guard !spares.isEmpty else { return nil }
            fallbackUsed = true
            return spares.removeFirst()
        }
    }

    /// A spare took a seat before the sitting opened (the preflight gate, docs/U25-SPEC.md).
    func noteFallback() { locked { fallbackUsed = true } }

    func append(_ claim: StoredClaim) { locked { claims.append(claim) } }

    /// A later round's answer replaces every earlier assessment of the seat.
    func forgetStances(of seat: String) {
        locked { for claim in stances.keys { stances[claim]?[seat] = nil } }
    }

    func record(stance: String, why: String, claim: String, seat: String) {
        locked { stances[claim, default: [:]][seat] = (stance, why) }
    }

    /// Claims of seats still in the verdict.
    var standingClaims: [StoredClaim] {
        locked {
            let out = Set(slots.filter(\.excluded).map(\.seat.name))
            return claims.filter { !out.contains($0.seat) }
        }
    }

    func assessments() -> [StoredAssessment] {
        locked {
            let out = Set(slots.filter(\.excluded).map(\.seat.name))
            return stances.flatMap { claim, bySeat in
                bySeat.filter { !out.contains($0.key) }.map { StoredAssessment(claim: claim, seat: $0.key, stance: $0.value.stance) }
            }
        }
    }
}
