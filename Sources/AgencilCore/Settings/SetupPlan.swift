import Foundation

/// One row of the broker's `harnesses` op: what is installed and whether it is signed in ("yes", "no", "unknown").
public struct HarnessFinding: Equatable, Sendable {
    public let kind: String
    public let found: Bool
    public let version: String?
    public let signedIn: String

    public init(kind: String, found: Bool, version: String?, signedIn: String) {
        self.kind = kind
        self.found = found
        self.version = version
        self.signedIn = signedIn
    }
}

/// A seat the first-run setup offers, with whether it can run now and whether it starts checked.
public struct ProposedSeat: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Found and signed in, or needing no sign-in (OpenCode's free models).
        case ready
        /// Found, but the probe could not tell whether it is signed in.
        case unconfirmed
        /// Found and signed out: the command that signs in.
        case signIn(command: String)
        /// Found, but Agencil cannot run a seat on it yet.
        case noAdapter
    }

    public let draft: SeatDraft
    public let state: State
    public let checked: Bool

    public init(draft: SeatDraft, state: State, checked: Bool) {
        self.draft = draft
        self.state = state
        self.checked = checked
    }
}

public struct SetupProposal: Equatable, Sendable {
    public let seats: [ProposedSeat]
    /// The setup kinds not found on this Mac, in `SetupPlan.kinds` order.
    public let missing: [String]

    public init(seats: [ProposedSeat], missing: [String]) {
        self.seats = seats
        self.missing = missing
    }
}

/// What the first-run setup proposes from the harnesses found (docs/U37-SPEC.md). Pure: the window shows it, the owner
/// adjusts it, and `ConfigEditor` validates and writes what they accept.
public enum SetupPlan {
    public static let kinds = ["claude", "codex", "opencode", "gemini", "antigravity"]

    private static let signInCommands = ["claude": "claude", "codex": "codex login", "opencode": "opencode auth login",
                                         "gemini": "gemini", "antigravity": "agy"]

    public static func propose(_ findings: [HarnessFinding]) -> SetupProposal {
        var seats: [ProposedSeat] = []
        var missing: [String] = []
        for kind in kinds {
            guard let finding = findings.first(where: { $0.kind == kind }), finding.found else {
                missing.append(kind)
                continue
            }
            seats += proposals(kind: kind, finding: finding)
        }
        return SetupProposal(seats: seats, missing: missing)
    }

    private static func proposals(kind: String, finding: HarnessFinding) -> [ProposedSeat] {
        let presets = SeatPreset.all.filter { $0.harness == kind }
        guard Adapter.runs(kind), !presets.isEmpty else {
            return [ProposedSeat(draft: SeatDraft(name: kind, harness: kind, model: ""), state: .noAdapter, checked: false)]
        }
        let state: ProposedSeat.State
        if kind == "opencode" || finding.signedIn == "yes" {
            state = .ready
        } else if finding.signedIn == "no" {
            state = .signIn(command: signInCommands[kind] ?? kind)
        } else {
            state = .unconfirmed
        }
        let usable = state == .ready || state == .unconfirmed
        // One seat per harness starts checked; further presets (OpenCode's other free models) are offered unchecked.
        return presets.enumerated().map { index, preset in
            ProposedSeat(draft: preset.draft, state: state, checked: usable && index == 0)
        }
    }

    /// A cross-vendor review council: the first seat of each vendor, quorum min(2, n); nil below two seats.
    public static func council(_ seats: [SeatDraft]) -> CouncilDraft? {
        var vendors = Set<String>()
        let picked = seats.filter { vendors.insert($0.vendor ?? $0.harness).inserted }.map(\.name)
        guard picked.count >= 2 else { return nil }
        return CouncilDraft(name: "review", seats: picked, rule: "any_blocker", quorum: min(2, picked.count), mode: "review")
    }

    /// One route per caller to the council, in order, each caller once.
    public static func routes(callers: [String], council: String) -> [RouteDraft] {
        var seen = Set<String>()
        return callers.filter { seen.insert($0).inserted }.map { RouteDraft(callers: [$0], target: council) }
    }

    /// The drafts whose name the config does not hold yet: an existing seat is left as it is, never renamed.
    public static func pending(_ seats: [SeatDraft], existing: Set<String>) -> [SeatDraft] {
        seats.filter { !existing.contains($0.name) }
    }
}
