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
    /// Seat names from the root of the chain to the seat that answers.
    public var chain: [String] = []
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

    static func encode(_ chain: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: chain)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func decode(_ text: String?) -> [String] {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    }

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

    /// Starts an exchange only when the thread has none in flight; the transcript is read in the same step, so two
    /// follow-ups can never both run on a transcript that lacks the other. Nil when one is still asking.
    public func beginExchange(thread: String, question: String, chain: [String]) throws -> (exchange: Exchange, transcript: [(asked: String, answered: String)])? {
        try ledger.locked {
            let rows = try ledger.query("SELECT seq, question, answer, state FROM exchanges WHERE thread_id = ? ORDER BY seq;", [thread]) {
                (seq: Int(Ledger.text($0, 0) ?? "") ?? 0, asked: Ledger.text($0, 1) ?? "", answer: Ledger.text($0, 2) ?? "",
                 state: Ledger.text($0, 3) ?? "")
            }
            if rows.contains(where: { $0.state == "asking" }) { return nil }
            let next = (rows.last?.seq ?? 0) + 1
            try ledger.run("INSERT INTO exchanges (thread_id, seq, question, state, chain, created_at) VALUES (?, ?, ?, 'asking', ?, ?);",
                           [thread, String(next), question, Self.encode(chain), Self.now()])
            try ledger.run("UPDATE runs SET status = 'asking', ended_at = NULL WHERE id = ?;", [thread])
            return (Exchange(seq: next, question: question, answer: nil, state: .asking, reason: nil, launchID: nil, chain: chain),
                    rows.filter { $0.state == "answered" }.map { (asked: $0.asked, answered: $0.answer) })
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

    /// Exchanges still asking, with the launch each is waiting on (nil when it never got one).
    public func unfinished() throws -> [(thread: String, seq: Int, launchID: String?)] {
        try ledger.locked {
            try ledger.query("SELECT thread_id, seq, launch_id FROM exchanges WHERE state = 'asking';", []) {
                (thread: Ledger.text($0, 0) ?? "", seq: Int(Ledger.text($0, 1) ?? "") ?? 0, launchID: Ledger.text($0, 2))
            }
        }
    }

    public func exchanges(thread: String) throws -> [Exchange] {
        try ledger.locked {
            try ledger.query("SELECT seq, question, answer, state, reason, launch_id, chain FROM exchanges WHERE thread_id = ? ORDER BY seq;", [thread]) { statement in
                Exchange(seq: Int(Ledger.text(statement, 0) ?? "") ?? 0, question: Ledger.text(statement, 1) ?? "",
                         answer: Ledger.text(statement, 2), state: Exchange.State(rawValue: Ledger.text(statement, 3) ?? "") ?? .failed,
                         reason: Ledger.text(statement, 4), launchID: Ledger.text(statement, 5),
                         chain: Self.decode(Ledger.text(statement, 6)))
            }
        }
    }
}
