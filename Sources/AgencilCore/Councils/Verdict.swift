import Foundation

/// One seat's standing at the end of a sitting.
struct SeatVote: Equatable {
    enum State: String { case answered, failed, abstained, recused, refused }
    let seat: String
    let vendor: String
    var state: State
    var vote: String?
    var reason: String?

    /// Answered, parsed and not abstained.
    var valid: Bool { state == .answered && vote != nil && vote != "abstain" }
}

struct StoredClaim: Equatable {
    let id: String
    let seat: String
    let vendor: String
    let claim: SeatClaim
}

struct StoredAssessment: Equatable {
    let claim: String
    let seat: String
    let stance: String
}

struct ClaimStanding: Equatable {
    let stored: StoredClaim
    var backers: [String]
    var dissenters: [String]
    var refuted: Bool
    var minority: Bool
}

struct VerdictInput {
    let council: Council
    /// Seats that sat: configured seats minus the recused.
    let convened: Int
    let votes: [SeatVote]
    let claims: [StoredClaim]
    /// Only the latest assessment of each seat on each claim.
    let assessments: [StoredAssessment]
    let conveneVendors: Set<String>
    let fallbackUsed: Bool
    let authorUnknown: Bool
    /// Nil when no synthesizer is configured.
    let synthesizerFailed: Bool?
}

struct VerdictOutcome: Equatable {
    let verdict: String
    let reasons: [String]
    let flags: [String]
    let claims: [ClaimStanding]
    let minority: [(claim: String, seat: String, vendor: String)]

    static func == (lhs: VerdictOutcome, rhs: VerdictOutcome) -> Bool {
        lhs.verdict == rhs.verdict && lhs.reasons == rhs.reasons && lhs.flags == rhs.flags && lhs.claims == rhs.claims
    }
}

/// The truth table of docs/PLAN.md U7, first match wins: synthesizer, quorum, independence of a high-risk council, rule.
enum VerdictTable {
    static func decide(_ input: VerdictInput) -> VerdictOutcome {
        let valid = input.votes.filter(\.valid)
        let vendors = Set(valid.map(\.vendor))
        let council = input.council
        let quorumMet: Bool
        if let explicit = council.quorum {
            quorumMet = valid.count >= explicit
        } else {
            quorumMet = valid.count >= input.convened / 2 + 1 && (council.seats.count < 2 || vendors.count >= 2)
        }
        var flags: [String] = []
        if input.fallbackUsed { flags.append("fallback_used") }
        if !input.conveneVendors.subtracting(vendors).isEmpty { flags.append("vendor_missing") }
        if quorumMet, council.seats.count >= 2, vendors.count == 1 { flags.append("single_vendor_quorum") }
        if input.authorUnknown { flags.append("author_unknown") }

        let standing = Self.standing(input, validCount: valid.count)
        func outcome(_ verdict: String, _ reasons: [String]) -> VerdictOutcome {
            VerdictOutcome(verdict: verdict, reasons: reasons, flags: flags, claims: standing.claims, minority: standing.minority)
        }
        if input.synthesizerFailed == true { return outcome("INCOMPLETE", ["synthesizer failed"]) }
        if !quorumMet { return outcome("INCOMPLETE", ["quorum: \(valid.count) valid vote(s)"]) }
        if council.highRisk, !flags.isEmpty { return outcome("INCOMPLETE", ["independence: " + flags.joined(separator: ", ")]) }
        switch council.rule {
        case .anyBlocker:
            let blockers = standing.claims.filter {
                ["p0", "p1"].contains($0.stored.claim.severity) && !$0.refuted && !$0.backers.isEmpty
            }
            if blockers.isEmpty { return outcome("PASS", ["no blocker"]) }
            return outcome("BLOCK", blockers.map { "blocker \($0.stored.id)" })
        case .unanimous:
            return valid.allSatisfy { $0.vote == "approve" } ? outcome("PASS", ["unanimous approve"]) : outcome("BLOCK", ["not unanimous"])
        case .majority:
            let approvals = valid.filter { $0.vote == "approve" }.count
            return approvals * 2 > valid.count ? outcome("PASS", ["majority approve"]) : outcome("BLOCK", ["no majority"])
        }
    }

    private static func standing(_ input: VerdictInput, validCount: Int) -> (claims: [ClaimStanding], minority: [(claim: String, seat: String, vendor: String)]) {
        let vendorOf = Dictionary(input.votes.map { ($0.seat, $0.vendor) }, uniquingKeysWith: { first, _ in first })
        var claims: [ClaimStanding] = []
        var minority: [(claim: String, seat: String, vendor: String)] = []
        for stored in input.claims {
            let ruling = input.assessments.filter { $0.claim == stored.id && $0.seat != stored.seat }
            let backers = [stored.seat] + ruling.filter { $0.stance == "support" }.map(\.seat)
            let dissenters = ruling.filter { $0.stance == "dispute" }.map(\.seat)
            let backing = Set(backers.compactMap { vendorOf[$0] ?? ($0 == stored.seat ? stored.vendor : nil) })
            let disputing = Set(dissenters.compactMap { vendorOf[$0] })
            let inMinority = 2 * backers.count <= validCount
            claims.append(ClaimStanding(stored: stored, backers: backers, dissenters: dissenters,
                                        refuted: disputing.count > backing.count, minority: inMinority))
            if inMinority {
                minority += backers.map { (claim: stored.id, seat: $0, vendor: vendorOf[$0] ?? stored.vendor) }
            }
        }
        return (claims, minority)
    }
}

/// One consult seat's view of another seat's position, with the label resolved to the seat it stands for.
struct ConsultStance: Equatable {
    let seat: String
    let about: String
    let stance: String
    let why: String?
}

struct ConsultInput {
    struct Answer {
        let seat: String
        let vendor: String
        let answer: ConsultAnswer
    }
    /// Seats that sat, and the council's explicit quorum when it has one.
    let convened: Int
    let quorum: Int?
    /// The seats with a valid answer, in council order.
    let answers: [Answer]
    let reviewRan: Bool
    let stances: [ConsultStance]
    let conveneVendors: Set<String>
    let fallbackUsed: Bool
    /// Nil when no synthesizer is configured.
    let synthesizerFailed: Bool?
    let noSynthesis: Bool
}

struct ConsultOutcome: Equatable {
    let verdict: String
    let reasons: [String]
    let flags: [String]
    /// Seats whose position more than half of the seats assessing it disagree with.
    let minority: [String]
}

/// The consult table of docs/U33-SPEC.md item 8, first match wins. Agreement counts only what the seats said of each
/// other in the review round: a summary cannot make a split council agree.
enum ConsultVerdict {
    static func decide(_ input: ConsultInput) -> ConsultOutcome {
        let answers = input.answers
        let vendors = Set(answers.map(\.vendor))
        let changed = answers.filter { $0.answer.kept == false }
        let (verdict, reason) = verdict(input)
        var flags: [String] = []
        if input.fallbackUsed { flags.append("fallback_used") }
        if !input.conveneVendors.subtracting(vendors).isEmpty { flags.append("vendor_missing") }
        if answers.count >= 2, vendors.count == 1 { flags.append("single_vendor") }
        if verdict == "AGREED", !changed.isEmpty { flags.append("converged_in_review") }
        if changed.contains(where: { $0.answer.newEvidence == false }) { flags.append("changed_without_evidence") }
        if input.noSynthesis { flags.append("no_synthesis") }
        // The review judged blind positions: a seat that moved off its own no longer holds what was disagreed with.
        let minority = answers.filter { $0.answer.kept != false }.map(\.seat).filter { seat in
            let about = input.stances.filter { $0.about == seat }
            return !about.isEmpty && 2 * about.filter { $0.stance == "disagree" }.count > about.count
        }
        return ConsultOutcome(verdict: verdict, reasons: [reason], flags: flags, minority: minority)
    }

    private static func verdict(_ input: ConsultInput) -> (String, String) {
        let count = input.answers.count
        if input.synthesizerFailed == true { return ("INCOMPLETE", "synthesizer failed") }
        if count < (input.quorum ?? input.convened / 2 + 1) { return ("INCOMPLETE", "quorum: \(count) valid answer(s)") }
        if count < 2 { return ("ANSWERED", "one seat answered") }
        if !input.reviewRan || input.stances.isEmpty { return ("ANSWERED", "the seats did not review each other") }
        if input.stances.allSatisfy({ $0.stance == "agree" }) { return ("AGREED", "every assessment agrees") }
        let apart = input.stances.filter { $0.stance != "agree" }.count
        return ("SPLIT", "\(apart) of \(input.stances.count) assessments disagree or agree in part")
    }
}
