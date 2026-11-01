import Foundation

/// What one run may cost at worst, or its best estimate when the seat is unbounded.
public struct Quote: Equatable, Sendable {
    public var dollars: Double
    public var tokens: Int
    public var seconds: Int
    /// A bounded seat cannot spend past its reservation; an unbounded one is only estimated.
    public var bounded: Bool
}

/// A quote that was admitted: its reservation row exists until the exchange settles.
public struct Admitted: Sendable {
    public let id: String
    public let quote: Quote
}

/// Durable reservations against budgets (docs/AGENT-API.md "Budgets and capacity"). Admission checks and inserts in
/// one `BEGIN IMMEDIATE` transaction, so two asks over a budget that fits one can never both pass.
struct BudgetStore: Sendable {
    let ledger: Ledger
    private static let epsilon = 1e-9

    struct Usage: Equatable {
        var spentDollars = 0.0, spentTokens = 0, reservedDollars = 0.0, reservedTokens = 0
    }

    /// The matching budgets of a request.
    static func matching(_ budgets: [Budget], route: String, root: String, vendor: String) -> [Budget] {
        budgets.filter { budget in
            switch budget.scope {
            case .route: budget.key == route
            case .root: budget.key == root
            case .vendor: budget.key == vendor
            }
        }
    }

    /// Nil when the quote fits every matching hard budget; else the refusal. With `commit`, the reservation row is
    /// written in the same transaction as the check. A `free` seat has no dollar worst case to bound, so a hard
    /// dollar budget does not refuse it for being unbounded.
    func admit(id: String, quote: Quote, budgets: [Budget], routeKey: String, rootKey: String, vendor: String,
               commit: Bool, free: Bool = false) throws -> Refusal? {
        try ledger.locked {
            try ledger.execute("BEGIN IMMEDIATE;")
            do {
                for budget in budgets where budget.hard {
                    if quote.bounded == false, budget.dollars != nil, !free { try rollback(); return Self.refusal }
                    let used = try usage(of: budget)
                    if let limit = budget.dollars, used.spentDollars + used.reservedDollars + quote.dollars > limit + Self.epsilon {
                        try rollback(); return Self.refusal
                    }
                    if let limit = budget.tokens, used.spentTokens + used.reservedTokens + quote.tokens > limit {
                        try rollback(); return Self.refusal
                    }
                }
                guard commit else { try rollback(); return nil }
                try ledger.run("""
                    INSERT INTO reservations (id, state, dollars, tokens, seconds, bounded, root_key, route_key, vendor, created_at)
                    VALUES (?, 'reserved', ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [id, String(quote.dollars), String(quote.tokens), String(quote.seconds), quote.bounded ? "1" : "0",
                          rootKey, routeKey, vendor, String(Date().timeIntervalSince1970)])
                for budget in budgets {
                    try ledger.run("INSERT INTO reservation_budgets (reservation_id, budget) VALUES (?, ?);", [id, budget.name])
                }
                try ledger.execute("COMMIT;")
                return nil
            } catch {
                try? ledger.execute("ROLLBACK;")
                throw error
            }
        }
    }

    static let refusal = Refusal(exit: 3, message: "refused: budget")

    private func rollback() throws { try ledger.execute("ROLLBACK;") }

    /// What a budget has spent and has set aside inside its window. A per-run budget accumulates nothing.
    func usage(of budget: Budget) throws -> Usage {
        if budget.window == .run { return Usage() }
        let since = budget.window == .week ? Self.weekStart() : 0
        // A hard budget never counts more than was reserved against it; an estimated one counts the report as it is.
        let dollars = "CAST(COALESCE(r.charged_dollars, r.dollars) AS REAL)"
        let tokens = "COALESCE(r.charged_tokens, r.tokens)"
        let charged = budget.hard ? ("MIN(\(dollars), CAST(r.dollars AS REAL))", "MIN(\(tokens), r.tokens)") : (dollars, tokens)
        let rows = try ledger.query("""
            SELECT r.state, COALESCE(SUM(\(charged.0)), 0), COALESCE(SUM(\(charged.1)), 0)
            FROM reservations r JOIN reservation_budgets b ON b.reservation_id = r.id
            WHERE b.budget = ? AND r.created_at >= ? AND r.state IN ('reserved', 'settled') GROUP BY r.state;
            """, [budget.name, String(since)]) {
            (state: Ledger.text($0, 0) ?? "", dollars: Double(Ledger.text($0, 1) ?? "") ?? 0, tokens: Int(Double(Ledger.text($0, 2) ?? "") ?? 0))
        }
        var usage = Usage()
        for row in rows {
            if row.state == "settled" { usage.spentDollars = row.dollars; usage.spentTokens = row.tokens }
            else { usage.reservedDollars = row.dollars; usage.reservedTokens = row.tokens }
        }
        return usage
    }

    /// Monday 00:00 UTC of this week.
    static func weekStart(now: Date = Date()) -> Double {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return start.timeIntervalSince1970
    }

    func bind(_ id: String, thread: String, seq: Int) throws {
        try ledger.locked {
            try ledger.run("UPDATE reservations SET thread_id = ?, seq = ? WHERE id = ?;", [thread, String(seq), id])
        }
    }

    /// Drops a reservation that never reached a run (the ask was refused after the check passed).
    func release(_ id: String) throws {
        try ledger.locked {
            // A reservation bound to an exchange is settled, never dropped: its charge stays on every budget.
            try ledger.run("DELETE FROM reservation_budgets WHERE reservation_id = ? AND reservation_id IN (SELECT id FROM reservations WHERE thread_id IS NULL);", [id])
            try ledger.run("DELETE FROM reservations WHERE id = ? AND thread_id IS NULL;", [id])
        }
    }

    /// Turns the reservation of an exchange into a charge. A report replaces the reservation, and a bounded seat is
    /// never charged above it; no report keeps the reservation in full.
    func settle(thread: String, seq: Int, reported: (dollars: Double, tokens: Int)?) throws {
        try ledger.locked {
            guard let row = try ledger.query("SELECT id, dollars, tokens, bounded FROM reservations WHERE thread_id = ? AND seq = ? AND state = 'reserved';",
                                             [thread, String(seq)], row: {
                (id: Ledger.text($0, 0) ?? "", dollars: Double(Ledger.text($0, 1) ?? "") ?? 0,
                 tokens: Int(Ledger.text($0, 2) ?? "") ?? 0, bounded: Ledger.text($0, 3) == "1")
            }).first else { return }
            var dollars = row.dollars, tokens = row.tokens, basis = "reserved"
            if let reported {
                basis = "provider"
                dollars = row.bounded ? min(reported.dollars, row.dollars) : reported.dollars
                tokens = row.bounded ? min(reported.tokens, row.tokens) : reported.tokens
            }
            try ledger.run("UPDATE reservations SET state = 'settled', charged_dollars = ?, charged_tokens = ?, basis = ? WHERE id = ?;",
                           [String(dollars), String(tokens), basis, row.id])
        }
    }

    /// Reservations a dead broker left behind stay charged in full, as nothing proves they were unused: those never
    /// bound to an exchange, and those whose exchange ended without its charge being written.
    func settleOrphans() throws {
        try ledger.locked {
            try ledger.run("""
                UPDATE reservations SET state = 'settled', charged_dollars = dollars, charged_tokens = tokens, basis = 'reserved'
                WHERE state = 'reserved' AND (thread_id IS NULL OR NOT EXISTS (
                    SELECT 1 FROM exchanges e WHERE e.thread_id = reservations.thread_id AND e.seq = reservations.seq AND e.state = 'asking'));
                """, [])
        }
    }

    func reservation(thread: String, seq: Int) throws -> (reserved: Quote, rootKey: String, charged: (dollars: Double, tokens: Int)?, basis: String?)? {
        try ledger.locked {
            try ledger.query("SELECT dollars, tokens, seconds, bounded, root_key, charged_dollars, charged_tokens, basis, state FROM reservations WHERE thread_id = ? AND seq = ?;",
                             [thread, String(seq)], row: {
                let quote = Quote(dollars: Double(Ledger.text($0, 0) ?? "") ?? 0, tokens: Int(Ledger.text($0, 1) ?? "") ?? 0,
                                  seconds: Int(Ledger.text($0, 2) ?? "") ?? 0, bounded: Ledger.text($0, 3) == "1")
                let settled = Ledger.text($0, 8) == "settled"
                let charged = settled ? (dollars: Double(Ledger.text($0, 5) ?? "") ?? 0, tokens: Int(Ledger.text($0, 6) ?? "") ?? 0) : nil
                return (reserved: quote, rootKey: Ledger.text($0, 4) ?? "", charged: charged, basis: settled ? Ledger.text($0, 7) : nil)
            }).first
        }
    }
}
