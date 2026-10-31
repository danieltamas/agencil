import Foundation

public enum AdjudicationAnswer: String, Sendable {
    case confirmed, refuted
    case cannotTell = "cannot tell"
}

public enum FindingStatus: Equatable, Sendable { case pending, confirmed, refuted, unresolved }
public enum OwnerDisposition: Sendable { case confirm, dismiss }

public struct OutcomeError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { "outcomes: \(message)" }
}

/// Outcome evidence, adjudication labels and the owner's final word, over the ledger's evidence and outcomes tables.
public final class OutcomeBook: @unchecked Sendable {
    /// A finding with no event for this long and no label is `unresolved`.
    static let unresolvedAfter: TimeInterval = 30 * 86_400

    let ledger: Ledger

    public init(ledger: Ledger) { self.ledger = ledger }

    /// One formatter: building one costs more than formatting; NSFormatter is safe to share across threads.
    nonisolated(unsafe) static let clock = ISO8601DateFormatter()

    static func stamp(_ date: Date) -> String { clock.string(from: date) }

    // MARK: Evidence

    @discardableResult
    public func recordCommit(sha: String, body: String, revertedBody: String?, at: Date) throws -> [String] {
        if CommitEvidenceParser.revertedSHA(in: body) != nil {
            // A revert names the fix it undoes only through that commit's own body; without it nothing is recorded.
            guard let revertedBody else { return [] }
            return try record(CommitEvidenceParser.claimIDs(in: revertedBody), source: "revert", detail: sha, at: at)
        }
        return try record(CommitEvidenceParser.claimIDs(in: body), source: "fix-commit", detail: sha, at: at)
    }

    @discardableResult
    public func recordPRDismissal(url: String, body: String, at: Date) throws -> [String] {
        try record(CommitEvidenceParser.claimIDs(in: body), source: "pr-dismissal", detail: url, at: at)
    }

    private func record(_ ids: [String], source: String, detail: String, at: Date) throws -> [String] {
        try ledger.locked {
            var recorded: [String] = []
            for id in ids where try exists(id) {
                try ledger.run("""
                    INSERT INTO evidence (id, claim_id, source, detail, created_at)
                    SELECT ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM evidence WHERE claim_id = ? AND source = ? AND detail = ?);
                    """, [SittingStore.newID("ev_"), id, source, detail, Self.stamp(at), id, source, detail])
                recorded.append(id)
            }
            return recorded
        }
    }

    private func exists(_ claim: String) throws -> Bool {
        try !ledger.query("SELECT 1 FROM claims WHERE id = ?;", [claim]) { _ in 1 }.isEmpty
    }

    public func evidence(claim: String) throws -> [EvidenceRecord] {
        try ledger.locked {
            try ledger.query("SELECT claim_id, source, COALESCE(detail, '') FROM evidence WHERE claim_id = ? ORDER BY created_at, id;", [claim]) {
                EvidenceRecord(claim: Ledger.text($0, 0) ?? "", source: Ledger.text($0, 1) ?? "", detail: Ledger.text($0, 2) ?? "")
            }
        }
    }

    // MARK: Adjudication

    /// The vendor of the seat that raised `claim`. An unknown claim or seat throws: the choice fails closed.
    private func raiserVendor(of claim: String, seats: [Seat]) throws -> String {
        let names = try ledger.locked {
            try ledger.query("""
                SELECT sr.seat FROM claims c JOIN seat_runs sr ON sr.id = c.seat_run_id WHERE c.id = ?;
                """, [claim]) { Ledger.text($0, 0) ?? "" }
        }
        guard let name = names.first else { throw OutcomeError(message: "claim \(claim) has no raising seat") }
        guard let vendor = seats.first(where: { $0.name == name })?.vendor, !vendor.isEmpty else {
            throw OutcomeError(message: "vendor of seat \(name) is unknown")
        }
        return vendor
    }

    public func adjudicator(for claim: String, seats: [Seat], synthesizerVendor: String) throws -> Seat? {
        guard !synthesizerVendor.isEmpty else { throw OutcomeError(message: "synthesizer vendor is unknown") }
        let raiser = try raiserVendor(of: claim, seats: seats)
        return seats.first { !$0.vendor.isEmpty && $0.vendor != raiser && $0.vendor != synthesizerVendor }
    }

    public func adjudicate(claim: String, answer: AdjudicationAnswer, by: Seat, seats: [Seat], synthesizerVendor: String,
                           certainty: String, reason: String, at: Date) throws {
        guard !synthesizerVendor.isEmpty else { throw OutcomeError(message: "synthesizer vendor is unknown") }
        let raiser = try raiserVendor(of: claim, seats: seats)
        // The adjudicator is whoever the configuration says that name is, never the caller's copy of the seat.
        guard let seat = seats.first(where: { $0.name == by.name }), !seat.vendor.isEmpty,
              seat.vendor != raiser, seat.vendor != synthesizerVendor else {
            throw OutcomeError(message: "seat \(by.name) may not adjudicate \(claim)")
        }
        try transaction {
            // The ledger lock is not re-entrant, so this reads the table rather than calling evidence(claim:).
            guard try !ledger.query("SELECT 1 FROM evidence WHERE claim_id = ?;", [claim], row: { _ in 1 }).isEmpty else {
                throw OutcomeError(message: "claim \(claim) has no evidence")
            }
            let owner = try ledger.query("SELECT 1 FROM outcomes WHERE claim_id = ? AND source = 'owner';", [claim]) { _ in 1 }
            guard owner.isEmpty else { throw OutcomeError(message: "the owner already decided \(claim)") }
            let label = answer == .cannotTell ? "cannot-tell" : answer.rawValue
            try insertOutcome(claim: claim, source: "adjudication", adjudicator: seat.name, certainty: certainty, label: label, detail: reason, at: at)
        }
    }

    public func dispose(claim: String, as disposition: OwnerDisposition, reason: String?, at: Date) throws {
        try transaction {
            guard try exists(claim) else { throw OutcomeError(message: "unknown claim \(claim)") }
            try insertOutcome(claim: claim, source: "owner", adjudicator: nil, certainty: "final",
                              label: disposition == .confirm ? "confirmed" : "refuted", detail: reason, at: at)
        }
    }

    /// The check and the write are one step, so a second connection cannot slip a decision between them.
    private func transaction(_ body: () throws -> Void) throws {
        try ledger.locked {
            try ledger.execute("BEGIN IMMEDIATE;")
            do {
                try body()
                try ledger.execute("COMMIT;")
            } catch {
                try? ledger.execute("ROLLBACK;")
                throw error
            }
        }
    }

    /// Stored stamps have whole-second precision, so a row is stamped strictly after the claim's latest one:
    /// ordering by time is then the order the decisions were made in.
    private func insertOutcome(claim: String, source: String, adjudicator: String?, certainty: String, label: String, detail: String?, at: Date) throws {
        let latest = try ledger.query("SELECT id, created_at FROM outcomes WHERE claim_id = ? ORDER BY created_at DESC, id DESC LIMIT 1;", [claim]) {
            (Ledger.text($0, 0), Ledger.text($0, 1))
        }.first
        var when = at
        if let stamp = latest?.1, let last = Self.clock.date(from: stamp), Self.stamp(last) >= Self.stamp(when) { when = last.addingTimeInterval(1) }
        try ledger.run("""
            INSERT INTO outcomes (id, claim_id, source, adjudicator, certainty, label, detail, supersedes, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [SittingStore.newID("oc_"), claim, source, adjudicator, certainty, label, detail, latest?.0, Self.stamp(when)])
    }

    // MARK: Status

    public func status(of claim: String, now: Date) throws -> FindingStatus {
        let states = try ledger.locked { try loadClaims(only: claim, now: now) }
        guard let state = states.first else { throw OutcomeError(message: "unknown claim \(claim)") }
        return state.status
    }
}
