import Foundation
import Security

/// A sitting as the ledger remembers it.
struct SittingRecord {
    let id: String
    let number: Int
    let council: String
    let state: String
    let round: String
    let reason: String?
    let verdict: [String: Any]?
}

/// The ledger rows of a sitting: its run, brief, snapshot, seat runs, claims, assessments and verdict.
struct SittingStore {
    let ledger: Ledger

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    static func newID(_ prefix: String, bytes count: Int = 8) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess { bytes = Array(UUID().uuidString.utf8.prefix(count)) }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the brief, the snapshot (once per distinct packet) and the sitting's run and number in one step.
    func open(council: String, snapshot: Snapshot, authorVendor: String, brief: String,
              project: String? = nil, caller: String? = nil) throws -> (id: String, number: Int) {
        let id = Self.newID("sit_")
        let briefID = Self.newID("br_")
        let stamp = Self.now()
        return try ledger.locked {
            let number = (try ledger.query("SELECT COALESCE(MAX(no), 0) FROM sittings;", []) { Int(Ledger.text($0, 0) ?? "") ?? 0 }.first ?? 0) + 1
            try ledger.run("INSERT INTO briefs (id, created_at, author_vendor, body) VALUES (?, ?, ?, ?);", [briefID, stamp, authorVendor, brief])
            try ledger.run("""
                INSERT INTO snapshots (id, brief_id, commit_sha, diff_hash, context_manifest, created_at)
                SELECT ?, ?, ?, ?, NULL, ? WHERE NOT EXISTS (SELECT 1 FROM snapshots WHERE id = ?);
                """, [snapshot.id, briefID, snapshot.commit, snapshot.patchHash, stamp, snapshot.id])
            try ledger.run("INSERT INTO runs (id, kind, snapshot_id, status, started_at) VALUES (?, 'sitting', ?, 'running', ?);",
                           [id, snapshot.id, stamp])
            try ledger.run("""
                INSERT INTO sittings (id, no, council, state, round, author_vendor, snapshot_id, created_at, repo, caller)
                VALUES (?, ?, ?, 'running', 'blind', ?, ?, ?, ?, ?);
                """, [id, String(number), council, authorVendor, snapshot.id, stamp, snapshot.repo, caller])
            if let project { try ledger.run("INSERT INTO run_origins (run_id, project) VALUES (?, ?);", [id, project]) }
            return (id, number)
        }
    }

    func setRound(_ id: String, _ round: String) throws {
        try ledger.locked { try ledger.run("UPDATE sittings SET round = ? WHERE id = ? AND state = 'running';", [round, id]) }
    }

    /// One row per seat-round, written when the round has resolved for that seat.
    func seatRun(sitting: String, seat: Seat, started: Date, ended: Date, exit: Int?) throws -> String {
        let id = Self.newID("sr_")
        let formatter = ISO8601DateFormatter()
        try ledger.locked {
            try ledger.run("""
                INSERT INTO seat_runs (id, run_id, seat, harness, model_id, started_at, ended_at, exit_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, [id, sitting, seat.name, seat.harness, seat.model, formatter.string(from: started), formatter.string(from: ended),
                      exit.map(String.init)])
        }
        return id
    }

    func claim(_ stored: StoredClaim, sitting: String, seatRun: String) throws {
        var body: [String: Any] = ["confidence": stored.claim.confidence]
        if let evidence = stored.claim.evidence { body["evidence"] = evidence }
        if let fix = stored.claim.fix { body["fix"] = fix }
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        try ledger.locked {
            try ledger.run("""
                INSERT INTO claims (id, run_id, seat_run_id, body, kind, severity, file, line, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [stored.id, sitting, seatRun, text, stored.claim.kind, stored.claim.severity, stored.claim.file,
                      stored.claim.line.map(String.init), Self.now()])
        }
    }

    func assessment(claim: String, stance: String, why: String?, sitting: String, snapshot: String, seatRun: String) throws {
        try ledger.locked {
            try ledger.run("""
                INSERT INTO assessments (id, claim_id, seat_run_id, stance, reason, created_at, run_id, snapshot_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, [Self.newID("as_"), claim, seatRun, stance, why, Self.now(), sitting, snapshot])
        }
    }

    /// Ends the sitting; `verdict` carries the row of the verdicts table when the sitting reached one.
    func finish(_ id: String, state: String, reason: String?, json: [String: Any]?,
                row: (verdict: String, flags: [String], minority: [[String: String]], snapshot: String)?) throws {
        let text = json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) }
        let stamp = Self.now()
        try ledger.locked {
            // The sitting is never `done` without its verdict row.
            try ledger.execute("BEGIN IMMEDIATE;")
            do {
                try ledger.run("UPDATE sittings SET state = ?, reason = ?, verdict = ?, ended_at = ? WHERE id = ? AND state = 'running';",
                               [state, reason, text, stamp, id])
                try ledger.run("UPDATE runs SET status = ?, ended_at = ? WHERE id = ?;", [state, stamp, id])
                if let row {
                    func encode(_ value: Any) -> String {
                        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("[]".utf8), as: UTF8.self)
                    }
                    try ledger.run("""
                        INSERT INTO verdicts (id, run_id, scope, verdict, independence_flags, minority, snapshot_id, created_at)
                        VALUES (?, ?, 'sitting', ?, ?, ?, ?, ?);
                        """, [Self.newID("vd_"), id, row.verdict, encode(row.flags), encode(row.minority), row.snapshot, stamp])
                }
                try ledger.execute("COMMIT;")
            } catch {
                try? ledger.execute("ROLLBACK;")
                throw error
            }
        }
    }

    func record(_ id: String) throws -> SittingRecord? {
        try ledger.locked {
            try ledger.query("SELECT id, no, council, state, round, reason, verdict FROM sittings WHERE id = ?;", [id]) {
                SittingRecord(id: Ledger.text($0, 0) ?? "", number: Int(Ledger.text($0, 1) ?? "") ?? 0, council: Ledger.text($0, 2) ?? "",
                              state: Ledger.text($0, 3) ?? "", round: Ledger.text($0, 4) ?? "", reason: Ledger.text($0, 5),
                              verdict: Ledger.text($0, 6).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
            }.first
        }
    }

    /// A broker that died mid-sitting leaves it running; the next start ends it.
    func failRunning(reason: String) throws {
        let stamp = Self.now()
        try ledger.locked {
            try ledger.run("UPDATE runs SET status = 'failed', ended_at = ? WHERE kind = 'sitting' AND status = 'running';", [stamp])
            try ledger.run("UPDATE sittings SET state = 'failed', reason = ?, ended_at = ? WHERE state = 'running';", [reason, stamp])
        }
    }
}

extension SittingStore {
    /// Who woke the sitting; nil when it is unknown or was recorded before callers were kept, so only the owner may stop it.
    func caller(of id: String) throws -> String? {
        try ledger.locked { try ledger.query("SELECT caller FROM sittings WHERE id = ?;", [id]) { Ledger.text($0, 0) }.first ?? nil }
    }
}
