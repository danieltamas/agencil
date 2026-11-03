import Foundation

/// The `costs` op: what every answered seat call on this Mac has cost, read-only (docs/U31-SPEC.md).
extension Broker {
    private static let entryLimit = 200

    /// One answered exchange with the names the report groups by. An origin on the thread itself wins over its sitting's.
    private static let callsSQL = """
        SELECT e.thread_id, e.created_at, t.seat, COALESCE(NULLIF(e.model, ''), 'unknown'), t.caller,
          COALESCE((SELECT project FROM run_origins WHERE run_id = t.id),
                   (SELECT project FROM run_origins WHERE run_id = l.sitting_id), 'unknown'),
          COALESCE(s.council, 'direct'), l.sitting_id, e.cost_usd, e.tokens_in, e.tokens_out
        FROM exchanges e JOIN threads t ON t.id = e.thread_id
        LEFT JOIN thread_rounds l ON l.thread_id = t.id
        LEFT JOIN sittings s ON s.id = l.sitting_id
        WHERE e.state = 'answered'
        """

    private struct Call {
        let thread: String, at: String, date: Date, seat: String, model: String, caller: String, project: String, council: String
        let sitting: String?
        let cost: Double?
        let tokensIn: Int?, tokensOut: Int?
    }

    func costsOp(_ request: [String: Any]) throws -> [String: Any] {
        let calendar = Calendar.current
        var window: (from: String, to: String)?
        var dayKey: String?
        if let raw = request["day"] {
            guard let text = raw as? String, let start = Self.localDay(text, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else {
                return Self.failure("usage: day must be YYYY-MM-DD", exit: 64)
            }
            let stamp = ISO8601DateFormatter()
            window = (stamp.string(from: start), stamp.string(from: end))
            dayKey = text
        }
        let stamp = ISO8601DateFormatter()
        let calls = try ledger.locked { () -> [Call] in
            let bounded = window == nil ? "" : " AND e.created_at >= ?1 AND e.created_at < ?2"
            return try ledger.query(Self.callsSQL + bounded + ";", window.map { [$0.from, $0.to] } ?? []) { row -> Call? in
                guard let thread = Ledger.text(row, 0), let at = Ledger.text(row, 1), let date = stamp.date(from: at) else { return nil }
                return Call(thread: thread, at: at, date: date, seat: Ledger.text(row, 2) ?? "unknown", model: Ledger.text(row, 3) ?? "unknown",
                            caller: Ledger.text(row, 4) ?? "unknown", project: Ledger.text(row, 5) ?? "unknown",
                            council: Ledger.text(row, 6) ?? "direct", sitting: Ledger.text(row, 7),
                            cost: Ledger.text(row, 8).flatMap(Double.init), tokensIn: Ledger.text(row, 9).flatMap { Int($0) },
                            tokensOut: Ledger.text(row, 10).flatMap { Int($0) })
            }.compactMap { $0 }
        }
        var data: [String: Any] = ["now": stamp.string(from: Date()), "rows": Self.costRows(calls, calendar: calendar)]
        if let dayKey {
            let mine = calls.filter { CostReport.day(of: $0.date, calendar: calendar) == dayKey }
                .sorted { ($0.at, $0.thread) > ($1.at, $1.thread) }.prefix(Self.entryLimit)
            data["entries"] = mine.map { call -> [String: Any] in
                var item: [String: Any] = ["thread": call.thread, "seat": call.seat, "model": call.model, "caller": call.caller,
                                           "project": call.project, "council": call.council, "at": call.at]
                if let sitting = call.sitting { item["sitting"] = sitting }
                if let cost = call.cost { item["cost"] = cost }
                if let tokensIn = call.tokensIn { item["tokens_in"] = tokensIn }
                if let tokensOut = call.tokensOut { item["tokens_out"] = tokensOut }
                return item
            }
        }
        return ["ok": true, "data": data]
    }

    /// One row per local day, project, council, seat, model and caller, oldest day first.
    private static func costRows(_ calls: [Call], calendar: Calendar) -> [[String: Any]] {
        struct Key: Hashable { let day, project, council, seat, model, caller: String }
        var totals: [Key: (calls: Int, unpriced: Int, cost: Decimal)] = [:]
        for call in calls {
            let key = Key(day: CostReport.day(of: call.date, calendar: calendar), project: call.project, council: call.council,
                          seat: call.seat, model: call.model, caller: call.caller)
            var entry = totals[key] ?? (0, 0, 0)
            entry.calls += 1
            if let cost = call.cost { entry.cost += Decimal(string: "\(cost)") ?? 0 } else { entry.unpriced += 1 }
            totals[key] = entry
        }
        return totals.sorted { ($0.key.day, $0.key.project, $0.key.council, $0.key.seat, $0.key.model, $0.key.caller)
            < ($1.key.day, $1.key.project, $1.key.council, $1.key.seat, $1.key.model, $1.key.caller) }
            .map { key, value in
                ["day": key.day, "project": key.project, "council": key.council, "seat": key.seat, "model": key.model,
                 "caller": key.caller, "calls": value.calls, "unpriced": value.unpriced, "cost": (value.cost as NSDecimalNumber).doubleValue]
            }
    }

    /// The start of a strict `YYYY-MM-DD` that is a real date, else nil.
    private static func localDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              CostReport.day(of: date, calendar: calendar) == text else { return nil }
        return date
    }
}
