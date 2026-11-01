import Foundation

/// What the `panel` op tells the app (docs/U8-SPEC.md "The `panel` op"), decoded once so views never touch JSON.
public struct PanelData: Sendable, Equatable {
    public struct SeatItem: Sendable, Equatable {
        public let name: String
        public let model: String
        public let up: Bool
        public let thinking: Bool
        public let probedAgo: Double?
        /// The preflight standing in the panel's words (docs/U25-SPEC.md); `not probed` without a fresh one.
        public let standing: String
        /// What the seat is: its harness, the vendor that trained the model and how it is paid for (`subscription`,
        /// `credit`, `free`, `local`). Empty when the broker predates them.
        public let harness: String
        public let vendor: String
        public let plan: String
        /// The preflight reason (`not_logged_in`, `usage_limit`, ...) of a fresh standing; nil without one.
        public let reason: String?
    }

    public struct Seats: Sendable, Equatable {
        public let total: Int
        public let up: Int
        public let thinking: Int
        public let items: [SeatItem]
    }

    public struct Thread: Sendable, Equatable {
        public let id: String
        public let caller: String
        public let seat: String
        public let question: String
        public let state: String
        public let reason: String?
        public let started: Date
        public let ended: Date?
    }

    public struct Sitting: Sendable, Equatable {
        public let id: String
        public let no: Int
        public let council: String
        public let state: String
        public let round: String
        public let started: Date
        public let ended: Date?
        public let costUSD: Double
        public let verdict: String?
    }

    public struct Finding: Sendable, Equatable {
        public let id: String
        public let severity: String
        public let file: String
        public let line: Int
        public let body: String
        public let backers: Int
        public let dissenters: Int
        public let minority: Bool
        public let disposition: String
    }

    public struct Week: Sendable, Equatable {
        public let spendUSD: Double
        public let budgetUSD: Double?
    }

    public struct Invalid: Error, Equatable { public let field: String }

    public let configured: Bool
    public let seats: Seats
    public let threads: [Thread]
    public let sittings: [Sitting]
    public let findings: [Finding]
    public let proposalsPending: Int
    public let week: Week
    public let live: Int

    public init(json: [String: Any]) throws {
        func field<T>(_ object: [String: Any], _ key: String, _ path: String) throws -> T {
            guard let value = object[key] as? T else { throw Invalid(field: path + key) }
            return value
        }
        func number(_ object: [String: Any], _ key: String, _ path: String) throws -> Double {
            guard let value = (object[key] as? NSNumber).map(\.doubleValue) else { throw Invalid(field: path + key) }
            return value
        }
        func whole(_ object: [String: Any], _ key: String, _ path: String) throws -> Int { Int(try number(object, key, path)) }
        func date(_ object: [String: Any], _ key: String, _ path: String) throws -> Date {
            guard let text = object[key] as? String, let value = ISO8601DateFormatter().date(from: text) else { throw Invalid(field: path + key) }
            return value
        }
        func optionalDate(_ object: [String: Any], _ key: String, _ path: String) throws -> Date? {
            object[key] == nil ? nil : try date(object, key, path)
        }
        func list(_ key: String) throws -> [[String: Any]] { try field(json, key, "") }

        configured = try field(json, "configured", "")
        let seatObject: [String: Any] = try field(json, "seats", "")
        let items: [[String: Any]] = try field(seatObject, "items", "seats.")
        seats = Seats(total: try whole(seatObject, "total", "seats."), up: try whole(seatObject, "up", "seats."),
                      thinking: try whole(seatObject, "thinking", "seats."),
                      items: try items.map {
                          SeatItem(name: try field($0, "name", "seats.items."), model: try field($0, "model", "seats.items."),
                                   up: try field($0, "up", "seats.items."), thinking: try field($0, "thinking", "seats.items."),
                                   probedAgo: ($0["probed_ago"] as? NSNumber)?.doubleValue,
                                   standing: $0["standing"] as? String ?? "not probed", harness: $0["harness"] as? String ?? "",
                                   vendor: $0["vendor"] as? String ?? "", plan: $0["plan"] as? String ?? "",
                                   reason: $0["reason"] as? String)
                      })
        threads = try list("threads").map {
            Thread(id: try field($0, "id", "threads."), caller: try field($0, "caller", "threads."), seat: try field($0, "seat", "threads."),
                   question: try field($0, "question", "threads."), state: try field($0, "state", "threads."),
                   reason: $0["reason"] as? String, started: try date($0, "started", "threads."),
                   ended: try optionalDate($0, "ended", "threads."))
        }
        sittings = try list("sittings").map {
            Sitting(id: try field($0, "id", "sittings."), no: try whole($0, "no", "sittings."), council: try field($0, "council", "sittings."),
                    state: try field($0, "state", "sittings."), round: try field($0, "round", "sittings."),
                    started: try date($0, "started", "sittings."), ended: try optionalDate($0, "ended", "sittings."),
                    costUSD: try number($0, "cost_usd", "sittings."), verdict: $0["verdict"] as? String)
        }
        findings = try list("findings").map {
            Finding(id: try field($0, "id", "findings."), severity: try field($0, "severity", "findings."),
                    file: try field($0, "file", "findings."), line: try whole($0, "line", "findings."),
                    body: try field($0, "body", "findings."), backers: try whole($0, "backers", "findings."),
                    dissenters: try whole($0, "dissenters", "findings."), minority: try field($0, "minority", "findings."),
                    disposition: try field($0, "disposition", "findings."))
        }
        proposalsPending = try whole(json, "proposals_pending", "")
        let weekObject: [String: Any] = try field(json, "week", "")
        week = Week(spendUSD: try number(weekObject, "spend_usd", "week."), budgetUSD: (weekObject["budget_usd"] as? NSNumber)?.doubleValue)
        live = try whole(json, "live", "")
    }
}
