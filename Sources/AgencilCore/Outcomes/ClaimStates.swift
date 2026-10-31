import Foundation
import SQLite3

/// A claim with what the outcome rules need, loaded in one query. "Fresh" is decided in SQL against the cutoff
/// (UTC ISO8601 text sorts as time) and so is "joins the previous claim", so no timestamp is decoded or parsed
/// and no kind, file or line is read for tens of thousands of claims.
struct ClaimState {
    let id: String
    let sitting: String
    let council: String
    let seat: String
    /// The deciding label: the owner's latest, else the latest adjudication label.
    let label: String?
    /// The label is the owner's final word.
    let byOwner: Bool
    /// The claim, its evidence or an outcome row is newer than the unresolved cutoff.
    let fresh: Bool
    /// Same sitting, kind and file as the previous claim in the load order and within 3 lines of it:
    /// the SQL twin of `FindingGrouper`'s proximity rule (synthesizer links are not used for scoring yet).
    let joinsPrevious: Bool

    var status: FindingStatus {
        switch label {
        case "confirmed": return .confirmed
        case "refuted": return .refuted
        default: return fresh ? .pending : .unresolved
        }
    }
}

extension OutcomeBook {
    /// Every claim raised by a seat in a sitting (ordered by sitting, kind, file, line), or just `only`
    /// (whose `joinsPrevious` is then meaningless). Call inside `ledger.locked`.
    func loadClaims(only: String? = nil, now: Date) throws -> [ClaimState] {
        let cutoff = Self.stamp(now.addingTimeInterval(-Self.unresolvedAfter))
        return try ledger.query("""
            SELECT c.id, c.run_id, s.council, sr.seat,
                (SELECT MAX((o.source = 'owner') || o.created_at || o.id || CASE o.label WHEN 'confirmed' THEN 'C' ELSE 'R' END)
                 FROM outcomes o WHERE o.claim_id = c.id AND o.label IN ('confirmed', 'refuted')),
                (c.created_at > ?1
                 OR EXISTS (SELECT 1 FROM evidence e WHERE e.claim_id = c.id AND e.created_at > ?1)
                 OR EXISTS (SELECT 1 FROM outcomes o WHERE o.claim_id = c.id AND o.created_at > ?1)),
                CASE WHEN c.kind IS NULL OR c.file IS NULL OR c.line IS NULL THEN 0
                     ELSE COALESCE(c.line - LAG(c.line) OVER (PARTITION BY c.run_id, c.kind, c.file ORDER BY c.line) <= 3, 0) END
            FROM claims c JOIN seat_runs sr ON sr.id = c.seat_run_id JOIN sittings s ON s.id = c.run_id\(only == nil ? "" : " WHERE c.id = ?2")
            ORDER BY c.run_id, c.kind, c.file, c.line;
            """, [cutoff] + (only.map { [$0] } ?? [])) { row in
            // Column 4 is the latest decisive row as "<1 if owner><stamp><id><C or R>": the owner outranks, then the newest.
            let decided = Ledger.text(row, 4)
            return ClaimState(id: Ledger.text(row, 0) ?? "", sitting: Ledger.text(row, 1) ?? "", council: Ledger.text(row, 2) ?? "",
                              seat: Ledger.text(row, 3) ?? "", label: decided.map { $0.hasSuffix("C") ? "confirmed" : "refuted" },
                              byOwner: decided?.hasPrefix("1") == true, fresh: sqlite3_column_int(row, 5) != 0,
                              joinsPrevious: sqlite3_column_int(row, 6) != 0)
        }
    }
}
