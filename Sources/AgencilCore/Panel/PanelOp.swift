import Foundation

/// The `panel` op: one read-only snapshot of everything the panel shows (docs/U8-SPEC.md "The `panel` op").
extension Broker {
    private static let listLimit = 200

    func panelOp() throws -> [String: Any] {
        let values = try ConfigStore(directory: directory).read().values
        _ = try NotifySettings(values: values)
        let config = try SeatConfig(values: values)
        let stamp = ISO8601DateFormatter()
        let weekStart = stamp.string(from: Self.weekStart(Date()))
        // Outside the ledger lock: the discovery cache may probe the Mac once it is ten minutes old.
        let world = discovery.world(environment: environment, home: directory)
        let problems = config.seats.map { seat -> String? in
            // An ollama seat is a request: its endpoint answering is the preflight's business, not a panel read's.
            if seat.harness == "ollama" { return seat.endpoint == nil ? "seat \(seat.name) has no endpoint" : nil }
            if case .failure(let problem) = Resolver.installed(seat, world) { return problem.reason }
            return nil
        }
        return try ledger.locked {
            let threads = try panelThreads(stamp: stamp)
            let sittings = try panelSittings()
            let thinking = try panelThinking()
            let items = try zip(config.seats, problems).map { seat, problem -> [String: Any] in
                var item: [String: Any] = ["name": seat.name, "model": seat.model, "up": problem == nil,
                                           "thinking": thinking.contains(seat.name), "plan": seat.plan.rawValue, "standing": "not probed",
                                           "harness": seat.harness, "vendor": seat.vendor]
                if let problem { item["problem"] = problem }
                if let standing = try preflights.fresh(seat, insideLock: true) {
                    // A fresh failed preflight takes the seat down; `busy` says nothing about the seat itself.
                    if standing.reason != .ok, standing.reason != .busy { item["up"] = false }
                    item["standing"] = standing.display
                    item["reason"] = standing.reason.rawValue
                    item["probed_ago"] = Date().timeIntervalSince(standing.probedAt)
                }
                return item
            }
            let weekly = config.budgets.filter { $0.window == .week }.compactMap(\.dollars)
            var week: [String: Any] = ["spend_usd": try panelSpend(since: weekStart)]
            if !weekly.isEmpty { week["budget_usd"] = weekly.reduce(0, +) }
            let data: [String: Any] = [
                "configured": !config.seats.isEmpty && !config.councils.isEmpty,
                "seats": ["total": items.count, "up": items.filter { $0["up"] as? Bool == true }.count,
                          "thinking": items.filter { $0["thinking"] as? Bool == true }.count, "items": items],
                "threads": threads, "sittings": sittings, "findings": try panelFindings(),
                "proposals_pending": try panelCount("""
                    SELECT count(*) FROM proposals WHERE status IN ('pending', 'proposed', 'reviewed')
                    AND id NOT IN (SELECT supersedes FROM proposals WHERE supersedes IS NOT NULL);
                    """),
                "week": week,
                "live": try panelCount("SELECT count(*) FROM sittings WHERE state = 'running';") + (try panelAsking()),
            ]
            return ["ok": true, "data": data, "data_note": Self.note]
        }
    }

    /// Monday 00:00 UTC of the week `date` falls in.
    static func weekStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private func panelCount(_ sql: String) throws -> Int {
        try ledger.query(sql, []) { Int(Ledger.text($0, 0) ?? "") ?? 0 }.first ?? 0
    }

    private func panelAsking() throws -> Int {
        try panelCount("""
            SELECT count(*) FROM threads t WHERE
            (SELECT state FROM exchanges WHERE thread_id = t.id ORDER BY seq DESC LIMIT 1) = 'asking';
            """)
    }

    private func panelThinking() throws -> Set<String> {
        Set(try ledger.query("""
            SELECT seat FROM seat_runs WHERE ended_at IS NULL AND started_at IS NOT NULL
            UNION SELECT t.seat FROM threads t WHERE
            (SELECT state FROM exchanges WHERE thread_id = t.id ORDER BY seq DESC LIMIT 1) = 'asking';
            """, []) { Ledger.text($0, 0) ?? "" })
    }

    private func panelSpend(since start: String) throws -> Double {
        try ledger.query("SELECT COALESCE(SUM(cost_usd), 0) FROM seat_runs WHERE started_at >= ?;", [start]) {
            Double(Ledger.text($0, 0) ?? "") ?? 0
        }.first ?? 0
    }

    private func panelThreads(stamp: ISO8601DateFormatter) throws -> [[String: Any]] {
        try ledger.query("""
            SELECT t.id, t.caller, t.seat, t.created_at,
              (SELECT question FROM exchanges WHERE thread_id = t.id ORDER BY seq LIMIT 1),
              (SELECT state FROM exchanges WHERE thread_id = t.id ORDER BY seq DESC LIMIT 1),
              (SELECT reason FROM exchanges WHERE thread_id = t.id ORDER BY seq DESC LIMIT 1),
              (SELECT ended_at FROM runs WHERE id = t.id)
            FROM threads t
            -- A sitting's per-round seat exchanges are threads too; they belong to the sitting's detail, not to the direct asks.
            -- A thread with a thread_rounds row is classified by it; only one from before that table is read from its prompt.
            WHERE NOT EXISTS (SELECT 1 FROM thread_rounds l WHERE l.thread_id = t.id AND l.sitting_id IS NOT NULL)
              AND NOT (NOT EXISTS (SELECT 1 FROM thread_rounds l WHERE l.thread_id = t.id)
                AND EXISTS (SELECT 1 FROM exchanges r WHERE r.thread_id = t.id AND r.seq = 1
                  AND r.question LIKE 'ROUND: %' AND instr(r.question, char(10) || 'SITTING: sit_') > 0))
            ORDER BY t.created_at DESC, t.id DESC LIMIT \(Self.listLimit);
            """, []) { row -> [String: Any] in
            let raw = Ledger.text(row, 5) ?? "failed"
            let state = ["asking", "answered"].contains(raw) ? raw : "failed"
            let question = (Ledger.text(row, 4) ?? "").split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            var item: [String: Any] = ["id": Ledger.text(row, 0) ?? "", "caller": Ledger.text(row, 1) ?? "", "seat": Ledger.text(row, 2) ?? "",
                                       "question": String(question.prefix(200)), "state": state, "started": Ledger.text(row, 3) ?? ""]
            if state == "failed" { item["reason"] = Ledger.text(row, 6) ?? raw }
            if let ended = Ledger.text(row, 7) { item["ended"] = ended }
            return item
        }
    }

    private func panelSittings() throws -> [[String: Any]] {
        try ledger.query("""
            SELECT s.id, s.no, s.council, s.state, s.round, s.created_at, s.ended_at, s.verdict,
              COALESCE(NULLIF((SELECT SUM(cost_usd) FROM seat_runs WHERE run_id = s.id), 0),
                (SELECT SUM(e.cost_usd) FROM thread_rounds r JOIN exchanges e ON e.thread_id = r.thread_id WHERE r.sitting_id = s.id), 0), s.reason,
              (SELECT group_concat(seat, char(10)) FROM (SELECT DISTINCT seat FROM seat_runs WHERE run_id = s.id ORDER BY seat))
            FROM sittings s ORDER BY s.created_at DESC, s.id DESC LIMIT \(Self.listLimit);
            """, []) { row -> [String: Any] in
            var item: [String: Any] = ["id": Ledger.text(row, 0) ?? "", "no": Int(Ledger.text(row, 1) ?? "") ?? 0,
                                       "council": Ledger.text(row, 2) ?? "", "state": Ledger.text(row, 3) ?? "",
                                       "round": Ledger.text(row, 4) ?? "", "started": Ledger.text(row, 5) ?? "",
                                       "cost_usd": Double(Ledger.text(row, 8) ?? "") ?? 0]
            if let ended = Ledger.text(row, 6) { item["ended"] = ended }
            if let reason = Ledger.text(row, 9), !reason.isEmpty { item["reason"] = reason }
            item["seats"] = (Ledger.text(row, 10) ?? "").split(separator: "\n").map(String.init)
            if let stored = Ledger.text(row, 7), !stored.isEmpty {
                let parsed = (try? JSONSerialization.jsonObject(with: Data(stored.utf8))) as? [String: Any]
                item["verdict"] = parsed.map { $0["verdict"] as? String ?? stored } ?? stored
            }
            return item
        }
    }

    func panelFindings() throws -> [[String: Any]] {
        try ledger.query("""
            SELECT c.id, c.severity, c.file, c.line, c.body,
              (SELECT label FROM outcomes WHERE claim_id = c.id AND source = 'owner'
                AND id NOT IN (SELECT supersedes FROM outcomes WHERE supersedes IS NOT NULL)
                ORDER BY created_at DESC, id DESC LIMIT 1),
              (SELECT count(DISTINCT seat_run_id) FROM assessments WHERE claim_id = c.id AND stance = 'support'),
              (SELECT count(DISTINCT seat_run_id) FROM assessments WHERE claim_id = c.id AND stance = 'dispute')
            FROM claims c JOIN sittings s ON s.id = c.run_id
            ORDER BY c.created_at DESC, c.id DESC LIMIT \(Self.listLimit);
            """, []) { row -> [String: Any] in
            let label = Ledger.text(row, 5) ?? ""
            let dissenters = Int(Ledger.text(row, 7) ?? "") ?? 0
            return ["id": Ledger.text(row, 0) ?? "", "severity": Ledger.text(row, 1) ?? "", "file": Ledger.text(row, 2) ?? "",
                    "line": Int(Ledger.text(row, 3) ?? "") ?? 0, "body": Ledger.text(row, 4) ?? "",
                    "disposition": label == "refuted" ? "dismissed" : ["confirmed", "dismissed", "will_fix"].contains(label) ? label : "open",
                    "backers": 1 + (Int(Ledger.text(row, 6) ?? "") ?? 0), "dissenters": dissenters, "minority": dissenters > 0]
        }
    }
}
