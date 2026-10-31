import Foundation

/// What each trigger has seen and every attempt it made (docs/U7-SPEC.md "Ledger and surfaces").
struct TriggerStore {
    let ledger: Ledger

    func state(_ trigger: String, _ key: String) throws -> String? { try ledger.locked { try read(trigger, key) } }

    /// The ledger lock is not re-entrant, so code already holding it reads through here.
    private func read(_ trigger: String, _ key: String) throws -> String? {
        try ledger.query("SELECT value FROM trigger_state WHERE trigger = ? AND key = ?;", [trigger, key]) { Ledger.text($0, 0) }.first ?? nil
    }

    func set(_ trigger: String, _ pairs: [(key: String, value: String)]) throws {
        try ledger.locked { for pair in pairs { try put(trigger, pair.key, pair.value) } }
    }

    private func put(_ trigger: String, _ key: String, _ value: String) throws {
        try ledger.run("INSERT INTO trigger_state (trigger, key, value) VALUES (?, ?, ?) ON CONFLICT (trigger, key) DO UPDATE SET value = excluded.value;",
                       [trigger, key, value])
    }

    /// What a candidate gives up before its wake: the state it moves on and the fire time, in one transaction. A broker
    /// that dies between this and the wake loses the fire; it can never fire the same candidate twice.
    func claim(_ trigger: String, at: Date, consume: [(key: String, value: String)]) throws -> [(key: String, value: String?)] {
        try ledger.locked {
            try ledger.execute("BEGIN IMMEDIATE;")
            do {
                let keys = consume.map(\.key) + ["last_fire"]
                let before = try keys.map { (key: $0, value: try read(trigger, $0)) }
                for pair in consume { try put(trigger, pair.key, pair.value) }
                try put(trigger, "last_fire", String(Int(at.timeIntervalSince1970)))
                try ledger.execute("COMMIT;")
                return before
            } catch {
                try? ledger.execute("ROLLBACK;")
                throw error
            }
        }
    }

    /// A wake that was not accepted: the claimed state goes back exactly as it was, and the attempt is kept.
    func release(_ trigger: String, _ before: [(key: String, value: String?)], key: String, outcome: String, detail: String, at: Date) throws {
        try ledger.locked {
            try ledger.execute("BEGIN IMMEDIATE;")
            do {
                for item in before {
                    if let value = item.value { try put(trigger, item.key, value) }
                    else { try ledger.run("DELETE FROM trigger_state WHERE trigger = ? AND key = ?;", [trigger, item.key]) }
                }
                try append(trigger, key: key, outcome: outcome, sitting: nil, detail: detail, at: at)
                try ledger.execute("COMMIT;")
            } catch {
                try? ledger.execute("ROLLBACK;")
                throw error
            }
        }
    }

    func fired(_ trigger: String, key: String, sitting: String, at: Date) throws {
        try ledger.locked { try append(trigger, key: key, outcome: "fired", sitting: sitting, detail: nil, at: at) }
    }

    private func append(_ trigger: String, key: String, outcome: String, sitting: String?, detail: String?, at: Date) throws {
        try ledger.run("INSERT INTO trigger_fires (id, trigger, key, outcome, sitting, detail, fired_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
                       [SittingStore.newID("tf_"), trigger, key, outcome, sitting, detail, ISO8601DateFormatter().string(from: at)])
    }

    /// The latest accepted fire of a trigger: when, and the sitting it opened.
    func last(_ trigger: String) throws -> (at: String, sitting: String)? {
        try ledger.locked {
            try ledger.query("SELECT fired_at, sitting FROM trigger_fires WHERE trigger = ? AND outcome = 'fired' ORDER BY rowid DESC LIMIT 1;",
                             [trigger]) { (Ledger.text($0, 0) ?? "", Ledger.text($0, 1) ?? "") }.first
        }
    }
}
