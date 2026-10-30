import Foundation
import Security

/// One question and what came of it.
public struct Exchange: Sendable, Equatable {
    public enum State: String, Sendable { case asking, answered, failed }
    public let seq: Int
    public let question: String
    public var answer: String?
    public var state: State
    public var reason: String?
    public var launchID: String?
}

public struct ThreadRecord: Sendable, Equatable {
    public let id: String
    /// What the caller first asked for (a seat or an alias): follow-ups are routed against it.
    public let requested: String
    public let seat: String
    public let caller: String
    public let substituted: String?
}

/// Threads, their exchanges and the request log, in the ledger. Rows of finished exchanges are final.
public struct ThreadStore: Sendable {
    let ledger: Ledger

    public init(ledger: Ledger) { self.ledger = ledger }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// One row per ask, whatever became of it. `outcome` is `refused`, `failed` or `accepted`.
    public func recordRequest(caller: String, outcome: String, runID: String? = nil) throws {
        try ledger.locked {
            try ledger.run("INSERT INTO requests (id, caller, run_id, created_at, outcome) VALUES (?, ?, ?, ?, ?);",
                           [UUID().uuidString, caller, runID, Self.now(), outcome])
        }
    }

    public func createThread(requested: String, seat: String, caller: String, substituted: String?) throws -> ThreadRecord {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess { bytes = Array(UUID().uuidString.utf8.prefix(8)) }
        let id = "th_" + bytes.map { String(format: "%02x", $0) }.joined()
        try ledger.locked {
            try ledger.run("INSERT INTO runs (id, kind, status, started_at) VALUES (?, 'thread', 'asking', ?);", [id, Self.now()])
            try ledger.run("INSERT INTO threads (id, requested, seat, caller, substituted, created_at) VALUES (?, ?, ?, ?, ?, ?);",
                           [id, requested, seat, caller, substituted, Self.now()])
        }
        return ThreadRecord(id: id, requested: requested, seat: seat, caller: caller, substituted: substituted)
    }

    public func thread(id: String) throws -> ThreadRecord? {
        try ledger.locked {
            try ledger.query("SELECT id, requested, seat, caller, substituted FROM threads WHERE id = ?;", [id]) { statement in
                ThreadRecord(id: Ledger.text(statement, 0) ?? "", requested: Ledger.text(statement, 1) ?? "",
                             seat: Ledger.text(statement, 2) ?? "", caller: Ledger.text(statement, 3) ?? "",
                             substituted: Ledger.text(statement, 4))
            }.first
        }
    }

    public func addExchange(thread: String, question: String) throws -> Exchange {
        try ledger.locked {
            let next = try ledger.query("SELECT COALESCE(MAX(seq), 0) + 1 FROM exchanges WHERE thread_id = ?;", [thread]) {
                Int(Ledger.text($0, 0) ?? "") ?? 1
            }.first ?? 1
            try ledger.run("INSERT INTO exchanges (thread_id, seq, question, state, created_at) VALUES (?, ?, ?, 'asking', ?);",
                           [thread, String(next), question, Self.now()])
            try ledger.run("UPDATE runs SET status = 'asking', ended_at = NULL WHERE id = ?;", [thread])
            return Exchange(seq: next, question: question, answer: nil, state: .asking, reason: nil, launchID: nil)
        }
    }

    public func attach(launch: String, thread: String, seq: Int) throws {
        try ledger.locked {
            try ledger.run("UPDATE exchanges SET launch_id = ? WHERE thread_id = ? AND seq = ?;", [launch, thread, String(seq)])
        }
    }

    public func finish(thread: String, seq: Int, state: Exchange.State, answer: String?, reason: String?) throws {
        try ledger.locked {
            try ledger.run("UPDATE exchanges SET state = ?, answer = ?, reason = ? WHERE thread_id = ? AND seq = ? AND state = 'asking';",
                           [state.rawValue, answer, reason, thread, String(seq)])
            try ledger.run("UPDATE runs SET status = ?, ended_at = ? WHERE id = ?;", [state.rawValue, Self.now(), thread])
        }
    }

    /// Exchanges still asking when the broker starts have lost their process: recovery has ended every launch.
    public func failUnfinished(reason: String) throws {
        try ledger.locked {
            try ledger.run("UPDATE exchanges SET state = 'failed', reason = ? WHERE state = 'asking';", [reason])
        }
    }

    public func exchanges(thread: String) throws -> [Exchange] {
        try ledger.locked {
            try ledger.query("SELECT seq, question, answer, state, reason, launch_id FROM exchanges WHERE thread_id = ? ORDER BY seq;", [thread]) { statement in
                Exchange(seq: Int(Ledger.text(statement, 0) ?? "") ?? 0, question: Ledger.text(statement, 1) ?? "",
                         answer: Ledger.text(statement, 2), state: Exchange.State(rawValue: Ledger.text(statement, 3) ?? "") ?? .failed,
                         reason: Ledger.text(statement, 4), launchID: Ledger.text(statement, 5))
            }
        }
    }
}
