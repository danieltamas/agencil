import Foundation

/// The learn loop: reads the scoreboard, writes proposals, has an independent seat review them and applies one
/// only on the owner's approval. `config.json` changes only in `approve` and `rollback`.
public final class LearnLoop: @unchecked Sendable {
    public static let minOutcomes = 20
    /// A seat whose confirmed share cannot reach this, even at the upper end of its Wilson interval, is a drop candidate.
    static let dropBelow = 0.30
    static let coverageBelow = 0.5
    static let maxIdeaLength = 500

    let ledger: Ledger
    let store: ConfigStore

    public init(ledger: Ledger, directory: URL) {
        self.ledger = ledger
        store = ConfigStore(directory: directory)
    }

    // MARK: Proposing

    private struct Draft {
        let kind: ProposalKind
        let council: String
        let seat: String?
        let replacement: String?
        let variable: String?
        let value: String?
        let n: Int
        let evidence: String
    }

    /// One slot per thing a council can have open at a time: a seat, the seat count, or the prompt.
    private static func slot(_ kind: ProposalKind, _ council: String, _ seat: String?) -> String {
        switch kind {
        case .dropSeat, .swapSeat: "seat|\(council)|\(seat ?? "")"
        case .addSeat: "add|\(council)"
        case .promptChange: "prompt|\(council)"
        }
    }

    @discardableResult
    public func propose(now: Date, candidates: [Seat], ideas: [PromptIdea]) throws -> [Proposal] {
        for idea in ideas {
            guard idea.variable.range(of: "^[a-z0-9][a-z0-9_-]{0,39}$", options: .regularExpression) != nil,
                  !idea.value.isEmpty, idea.value.count <= Self.maxIdeaLength else {
                throw LearnError(message: "prompt idea \(idea.variable) is not a valid variable and value")
            }
        }
        let config = try SeatConfig(values: store.read().values)
        let cells = try OutcomeBook(ledger: ledger).scoreboard(now: now)
        return try transaction {
            let existing = try loadProposals()
            var taken = Set(existing.filter(\.isOpen).map { Self.slot($0.kind, $0.council, $0.seat) })
            var written: [Proposal] = []
            for draft in drafts(config: config, cells: cells, candidates: candidates, ideas: ideas, existing: existing)
            where taken.insert(Self.slot(draft.kind, draft.council, draft.seat)).inserted {
                let body = ProposalBody(council: draft.council, seat: draft.seat, replacement: draft.replacement,
                                        variable: draft.variable, value: draft.value, n: draft.n)
                let id = SittingStore.newID("pr_")
                try ledger.run("""
                    INSERT INTO proposals (id, kind, body, evidence, status, supersedes, created_at)
                    VALUES (?, ?, ?, ?, 'proposed', NULL, ?);
                    """, [id, draft.kind.rawValue, try body.encoded(), draft.evidence, OutcomeBook.stamp(now)])
                if let proposal = Proposal(id: id, kind: draft.kind.rawValue, status: "proposed", evidence: draft.evidence, body: try body.encoded()) {
                    written.append(proposal)
                }
            }
            return written
        }
    }

    private func drafts(config: SeatConfig, cells: [SeatScore], candidates: [Seat], ideas: [PromptIdea], existing: [Proposal]) -> [Draft] {
        var out: [Draft] = []
        for council in config.councils {
            let held = council.seats.compactMap { name in cells.first { $0.council == council.name && $0.seat == name } }
            let total = Share(held.reduce(0) { $0 + $1.confirmedShare.numerator }, of: held.reduce(0) { $0 + $1.confirmedShare.denominator })

            for cell in held where cell.confirmedShare.denominator >= Self.minOutcomes {
                guard let upper = cell.confirmedShare.interval?.upper, upper < Self.dropBelow,
                      let seat = config.seat(named: cell.seat) else { continue }
                let evidence = Self.evidence(n: cell.confirmedShare.denominator, council: council.name, seat: cell.seat,
                                             share: cell.confirmedShare, upper: upper)
                let swapIn = candidates.first { !council.seats.contains($0.name) && !$0.vendor.isEmpty && !seat.vendor.isEmpty && $0.vendor != seat.vendor }
                if let swapIn {
                    out.append(Draft(kind: .swapSeat, council: council.name, seat: cell.seat, replacement: swapIn.name,
                                     variable: nil, value: nil,
                                     n: cell.confirmedShare.denominator, evidence: evidence))
                } else if council.seats.count > 2 {
                    out.append(Draft(kind: .dropSeat, council: council.name, seat: cell.seat, replacement: nil,
                                     variable: nil, value: nil,
                                     n: cell.confirmedShare.denominator, evidence: evidence))
                }
            }

            guard total.denominator >= Self.minOutcomes else { continue }
            let covered = held.filter { $0.coverage.denominator >= Self.minOutcomes }
            if covered.count >= 2, covered.allSatisfy({ ($0.coverage.value ?? 1) < Self.coverageBelow }),
               let added = candidates.first(where: { !council.seats.contains($0.name) }) {
                out.append(Draft(kind: .addSeat, council: council.name, seat: nil, replacement: added.name,
                                 variable: nil, value: nil, n: total.denominator,
                                 evidence: Self.evidence(n: total.denominator, council: council.name, seat: nil, share: total,
                                                         coverage: covered)))
            }
            for idea in ideas where idea.council == council.name {
                let applied = existing.filter { $0.kind == .promptChange && $0.council == council.name && $0.status == "applied" }
                guard applied.allSatisfy({ $0.variable == idea.variable }) else { continue }
                out.append(Draft(kind: .promptChange, council: council.name, seat: nil, replacement: nil,
                                 variable: idea.variable, value: idea.value, n: total.denominator,
                                 evidence: Self.evidence(n: total.denominator, council: council.name, seat: nil, share: total)))
            }
        }
        return out
    }

    private static func evidence(n: Int, council: String, seat: String?, share: Share, upper: Double? = nil, coverage: [SeatScore] = []) -> String {
        var cell: [String: Any] = ["council": council]
        if let seat { cell["seat"] = seat }
        if let upper { cell["wilsonUpper"] = upper }
        if !coverage.isEmpty {
            cell["coverage"] = coverage.map { ["seat": $0.seat, "numerator": $0.coverage.numerator, "denominator": $0.coverage.denominator] as [String: Any] }
        }
        let object: [String: Any] = ["n": n, "cell": cell, "confirmedShare": ["numerator": share.numerator, "denominator": share.denominator]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Listing

    public func proposals() throws -> [Proposal] { try ledger.locked { try loadProposals() } }

    /// Call inside `ledger.locked`; rows that do not decode are skipped rather than guessed at.
    func loadProposals(id: String? = nil) throws -> [Proposal] {
        try ledger.query("""
            SELECT id, kind, status, COALESCE(evidence, ''), body FROM proposals\(id == nil ? "" : " WHERE id = ?1") ORDER BY rowid;
            """, id.map { [$0] } ?? []) { row in
            Proposal(id: Ledger.text(row, 0) ?? "", kind: Ledger.text(row, 1) ?? "", status: Ledger.text(row, 2) ?? "",
                     evidence: Ledger.text(row, 3) ?? "", body: Ledger.text(row, 4) ?? "")
        }.compactMap { $0 }
    }

    /// The change of one proposal, checked against the status it must still have, so two callers cannot both win.
    func transition(_ id: String, from allowed: Set<String>, to status: String, _ change: (Proposal) throws -> ProposalBody) throws {
        try transaction {
            guard let proposal = try loadProposals(id: id).first else { throw LearnError(message: "unknown proposal \(id)") }
            guard allowed.contains(proposal.status) else { throw LearnError(message: "proposal \(id) is \(proposal.status)") }
            try ledger.run("UPDATE proposals SET status = ?, body = ? WHERE id = ?;", [status, try change(proposal).encoded(), id])
        }
    }

    /// `undo` runs when the commit itself fails after `body` changed something outside the ledger.
    func transaction<T>(undoing undo: () -> Void = {}, _ body: () throws -> T) throws -> T {
        try ledger.locked {
            try ledger.execute("BEGIN IMMEDIATE;")
            do {
                let result = try body()
                do { try ledger.execute("COMMIT;") } catch { undo(); throw error }
                return result
            } catch {
                try? ledger.execute("ROLLBACK;")
                throw error
            }
        }
    }
}
