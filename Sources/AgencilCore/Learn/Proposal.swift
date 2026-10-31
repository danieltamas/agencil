import Foundation

public enum ProposalKind: String, Sendable {
    case dropSeat = "drop_seat", addSeat = "add_seat", swapSeat = "swap_seat", promptChange = "prompt_change"
}

public enum ReviewVerdict: String, Sendable { case endorse, object }

/// A prompt variable the owner wants tried on one council.
public struct PromptIdea: Equatable, Sendable {
    public let council: String
    public let variable: String
    public let value: String

    public init(council: String, variable: String, value: String) {
        self.council = council
        self.variable = variable
        self.value = value
    }
}

public struct LearnError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { "learn: \(message)" }
}

public struct ConfigVersion: Equatable, Sendable {
    public let version: Int
    public let hash: String
    public let body: String
}

public struct Proposal: Equatable, Sendable {
    public let id: String
    public let kind: ProposalKind
    public let council: String
    /// The seat dropped or swapped out.
    public let seat: String?
    /// The seat added or swapped in.
    public let replacement: String?
    public let variable: String?
    public let value: String?
    /// proposed, reviewed, applied, rejected, rolled_back.
    public let status: String
    /// Decided findings behind the proposal.
    public let n: Int
    /// JSON text: {"n", "cell", "confirmedShare": {"numerator", "denominator"}}.
    public let evidence: String
    public let reviewer: String?
    public let verdict: ReviewVerdict?
    let reviewRevision: Int64?
    let appliedVersion: Int?
    let note: String?
    let reviewedAt: String?

    var isOpen: Bool { status == "proposed" || status == "reviewed" }
}

/// What a proposal stores in the `body` column; everything else is a column or derived.
struct ProposalBody: Codable {
    var council: String
    var seat: String?
    var replacement: String?
    var variable: String?
    var value: String?
    var n: Int
    var reviewer: String?
    var verdict: String?
    var note: String?
    var reviewedAt: String?
    var reviewRevision: Int64?
    var appliedVersion: Int?

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension Proposal {
    init?(id: String, kind: String, status: String, evidence: String, body: String) {
        guard let kind = ProposalKind(rawValue: kind),
              let parsed = try? JSONDecoder().decode(ProposalBody.self, from: Data(body.utf8)) else { return nil }
        self.init(id: id, kind: kind, council: parsed.council, seat: parsed.seat, replacement: parsed.replacement,
                  variable: parsed.variable, value: parsed.value, status: status, n: parsed.n, evidence: evidence,
                  reviewer: parsed.reviewer, verdict: parsed.verdict.flatMap(ReviewVerdict.init(rawValue:)),
                  reviewRevision: parsed.reviewRevision,
                  appliedVersion: parsed.appliedVersion, note: parsed.note, reviewedAt: parsed.reviewedAt)
    }

    var storedBody: ProposalBody {
        ProposalBody(council: council, seat: seat, replacement: replacement,
                     variable: variable, value: value, n: n, reviewer: reviewer, verdict: verdict?.rawValue,
                     note: note, reviewedAt: reviewedAt, reviewRevision: reviewRevision, appliedVersion: appliedVersion)
    }
}
