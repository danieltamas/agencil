import Foundation

/// The `detail` op: one thread's whole exchange, or one sitting's brief, verdict and every round's seat answers.
/// Read-only, for the panel and any agent that wants to inspect a deliberation after it ended (docs/AGENT-API.md "detail").
/// A figure the ledger does not hold is left out, never estimated: cost and tokens appear only when the seat reported them.
extension Broker {
    private static let textLimit = 32_768

    func detailOp(_ request: [String: Any]) throws -> [String: Any] {
        guard let id = request["id"] as? String else { throw Failure(message: "usage: detail needs an id") }
        let config = (try? ConfigStore(directory: directory).read().values).flatMap { try? SeatConfig(values: $0) }
        if id.hasPrefix("th_") { return ["ok": true, "data": try threadDetail(id, config: config), "data_note": Self.note] }
        if id.hasPrefix("sit_") { return ["ok": true, "data": try sittingDetail(id, config: config), "data_note": Self.note] }
        throw Failure(message: "unknown id \(id)")
    }

    private static func capped(_ text: String) -> String { String(text.prefix(textLimit)) }

    /// What the seat itself reported for an exchange; a reservation charged in full as a fallback is not a report.
    private func reported(thread: String, seq: Int) -> (dollars: Double, tokens: Int)? {
        guard let found = try? budgets.reservation(thread: thread, seq: seq), found.basis == "provider" else { return nil }
        return found.charged
    }

    private func addReport(_ row: inout [String: Any], thread: String, seq: Int) {
        guard let report = reported(thread: thread, seq: seq) else { return }
        row["cost_usd"] = report.dollars
        row["tokens"] = report.tokens
    }

    private func addSeat(_ row: inout [String: Any], name: String, config: SeatConfig?) {
        guard let seat = config?.seat(named: name) else { return }
        row["model"] = seat.model
        row["harness"] = seat.harness
    }

    private func threadDetail(_ id: String, config: SeatConfig?) throws -> [String: Any] {
        guard let thread = try threads.thread(id: id) else { throw Failure(message: "unknown id \(id)") }
        let exchanges = try threads.exchanges(thread: id).map { exchange -> [String: Any] in
            var row: [String: Any] = ["seq": exchange.seq, "question": Self.capped(exchange.question), "state": exchange.state.rawValue]
            if let answer = exchange.answer { row["answer"] = Self.capped(answer) }
            if let reason = exchange.reason { row["reason"] = reason }
            addReport(&row, thread: id, seq: exchange.seq)
            return row
        }
        var data: [String: Any] = ["thread": id, "caller": thread.caller, "seat": thread.seat, "exchanges": exchanges]
        addSeat(&data, name: thread.seat, config: config)
        if let project = try ledger.query("SELECT project FROM run_origins WHERE run_id = ?;", [id], row: { Ledger.text($0, 0) }).first ?? nil {
            data["project"] = project
        }
        return data
    }

    private func sittingDetail(_ id: String, config: SeatConfig?) throws -> [String: Any] {
        guard let record = try sittingRows.record(id) else { throw Failure(message: "unknown id \(id)") }
        var data: [String: Any] = ["sitting": id, "no": record.number, "council": record.council, "state": record.state, "round": record.round,
                                   "verdict": record.verdict ?? NSNull()]
        if let reason = record.reason { data["reason"] = reason }
        let source = try ledger.query("""
            SELECT s.snapshot_id, s.repo, b.body, (SELECT project FROM run_origins WHERE run_id = s.id) FROM sittings s
            LEFT JOIN snapshots n ON n.id = s.snapshot_id LEFT JOIN briefs b ON b.id = n.brief_id WHERE s.id = ?;
            """, [id]) { (snapshot: Ledger.text($0, 0), repo: Ledger.text($0, 1), brief: Ledger.text($0, 2), project: Ledger.text($0, 3)) }.first
        if let snapshot = source?.snapshot { data["snapshot"] = snapshot }
        if let repo = source?.repo { data["repo"] = repo }
        if let brief = source?.brief { data["brief"] = Self.capped(brief) }
        if let project = source?.project { data["project"] = project }

        let seats = try ledger.query("""
            SELECT t.id, t.seat, t.created_at, (SELECT ended_at FROM runs WHERE id = t.id), e.question, e.answer, e.state, e.reason
            FROM threads t JOIN exchanges e ON e.thread_id = t.id AND e.seq = 1
            WHERE e.question LIKE 'ROUND: %' AND instr(e.question, ?) > 0 ORDER BY t.created_at, t.id;
            """, ["\nSITTING: \(id)\n"]) { row -> (header: RoundPromptHeader?, seat: [String: Any]) in
            let thread = Ledger.text(row, 0) ?? ""
            let name = Ledger.text(row, 1) ?? ""
            var seat: [String: Any] = ["seat": name, "thread": thread, "started": Ledger.text(row, 2) ?? "", "state": Ledger.text(row, 6) ?? "failed"]
            if let ended = Ledger.text(row, 3) { seat["ended"] = ended }
            if let answer = Ledger.text(row, 5) { seat["answer"] = Self.capped(answer) }
            if let reason = Ledger.text(row, 7) { seat["reason"] = reason }
            addReport(&seat, thread: thread, seq: 1)
            addSeat(&seat, name: name, config: config)
            return (RoundPromptHeader(prompt: Ledger.text(row, 4) ?? ""), seat)
        }
        if let first = seats.first?.header {
            data["change_kind"] = first.changeKind
            data["question"] = Self.capped(first.question)
            if let range = first.diffRange { data["diff_range"] = range }
        }
        var order: [String] = []
        var bySeats: [String: [[String: Any]]] = [:]
        for (header, seat) in seats {
            let round = header?.round ?? "round"
            if bySeats[round] == nil { order.append(round) }
            bySeats[round, default: []].append(seat)
        }
        data["rounds"] = order.map { ["round": $0, "seats": bySeats[$0] ?? []] as [String: Any] }
        return data
    }
}
