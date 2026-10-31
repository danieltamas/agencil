import Foundation

/// One cell of the scoreboard: a seat in a council type. There is no recall here; recall exists only on the golden set.
public struct SeatScore: Equatable, Sendable {
    public let seat: String
    public let council: String
    public let confirmedShare: Share
    public let coverage: Share
    public let participation: Share
    public let costPerConfirmed: Double?
    public let medianSeconds: Double?
}

struct SeatRun {
    let sitting: String
    let council: String
    let seat: String
    let valid: Bool
    let cost: Double
    let seconds: Double?
}

private struct Cell: Hashable {
    let council: String
    let seat: String
}

/// What one (seat, council) cell has earned so far, tallied while the findings stream past.
private struct Tally {
    var confirmed = 0
    var decided = 0
    var confirmedBySitting: [String: Int] = [:]
}

extension OutcomeBook {
    /// Calls `visit` once per finding with its council, sitting, credited seats and decided status. Claims arrive
    /// ordered by sitting, kind, file, line, and a claim that joins its neighbour shares its finding, so each
    /// finding is one run of consecutive claims and the pass needs no per-finding storage.
    func judged(now: Date, _ visit: (_ council: String, _ sitting: String, _ seats: [String], _ status: FindingStatus) -> Void) throws {
        let states = try ledger.locked { try loadClaims(now: now) }
        var seats: [String] = []
        var first = 0, owner = -1, confirmed = false, refuted = false, pending = false

        func flush(_ end: Int) {
            let lead = states[first]
            let status: FindingStatus
            if owner >= 0 {
                status = states[owner].status   // the owner's word on any claim of the finding is final
            } else if confirmed && refuted {
                status = lead.status   // the claims disagree: the lowest id decides
            } else if confirmed {
                status = .confirmed
            } else if refuted {
                status = .refuted
            } else {
                status = pending ? .pending : .unresolved
            }
            visit(lead.council, lead.sitting, seats, status)
        }

        for index in states.indices {
            let state = states[index]
            if index > 0 && !state.joinsPrevious {
                flush(index)
                seats.removeAll(keepingCapacity: true)
                first = index; owner = -1; confirmed = false; refuted = false; pending = false
            } else if state.id < states[first].id {
                first = index
            }
            if state.byOwner, owner < 0 || state.id < states[owner].id { owner = index }
            if !seats.contains(state.seat) { seats.append(state.seat) }
            switch state.status {
            case .confirmed: confirmed = true
            case .refuted: refuted = true
            case .pending: pending = true
            case .unresolved: break
            }
        }
        if !states.isEmpty { flush(states.count) }
    }


    func seatRuns() throws -> [SeatRun] {
        let formatter = Self.clock
        return try ledger.locked {
            try ledger.query("""
                SELECT sr.run_id, s.council, sr.seat, sr.exit_code, sr.cost_usd, sr.started_at, sr.ended_at
                FROM seat_runs sr JOIN sittings s ON s.id = sr.run_id;
                """, []) { row in
                let start = Ledger.text(row, 5).flatMap(formatter.date), end = Ledger.text(row, 6).flatMap(formatter.date)
                return SeatRun(sitting: Ledger.text(row, 0) ?? "", council: Ledger.text(row, 1) ?? "", seat: Ledger.text(row, 2) ?? "",
                               valid: Ledger.text(row, 3) == "0", cost: Ledger.text(row, 4).flatMap(Double.init) ?? 0,
                               seconds: start.flatMap { start in end.map { $0.timeIntervalSince(start) } })
            }
        }
    }


    /// Every (seat, council) cell. A valid answer is a seat run that exited 0. Pending and unresolved findings
    /// count in no numerator and no denominator.
    public func scoreboard(now: Date) throws -> [SeatScore] {
        var runsByCell: [Cell: [SeatRun]] = [:]
        for run in try seatRuns() { runsByCell[Cell(council: run.council, seat: run.seat), default: []].append(run) }

        var tallies: [Cell: Tally] = [:]
        var confirmedInSitting: [String: Int] = [:]
        try judged(now: now) { council, sitting, seats, status in
            if status == .confirmed { confirmedInSitting[sitting, default: 0] += 1 }
            guard status == .confirmed || status == .refuted else { return }
            for seat in seats {
                let cell = Cell(council: council, seat: seat)
                tallies[cell, default: Tally()].decided += 1
                if status == .confirmed {
                    tallies[cell, default: Tally()].confirmed += 1
                    tallies[cell, default: Tally()].confirmedBySitting[sitting, default: 0] += 1
                }
            }
        }

        return runsByCell.keys.sorted { ($0.council, $0.seat) < ($1.council, $1.seat) }.map { cell in
            let runs = runsByCell[cell] ?? [], tally = tallies[cell] ?? Tally()
            let seated = Set(runs.map(\.sitting)), valid = Set(runs.filter(\.valid).map(\.sitting))
            let reachable = valid.reduce(0) { $0 + (confirmedInSitting[$1] ?? 0) }
            let raised = valid.reduce(0) { $0 + (tally.confirmedBySitting[$1] ?? 0) }
            let times = runs.compactMap(\.seconds).sorted()
            let middle = times.count / 2
            let median = times.isEmpty ? nil : (times.count % 2 == 1 ? times[middle] : (times[middle - 1] + times[middle]) / 2)
            return SeatScore(seat: cell.seat, council: cell.council, confirmedShare: Share(tally.confirmed, of: tally.decided),
                             coverage: Share(raised, of: reachable), participation: Share(valid.count, of: seated.count),
                             costPerConfirmed: tally.confirmed == 0 ? nil : runs.reduce(0) { $0 + $1.cost } / Double(tally.confirmed),
                             medianSeconds: median)
        }
    }

    /// Confirmed findings both seats raised over confirmed findings either raised, within one council.
    public func overlap(_ a: String, _ b: String, council: String, now: Date) throws -> Double? {
        var either = 0, both = 0
        try judged(now: now) { held, _, seats, status in
            guard held == council, status == .confirmed else { return }
            let hasA = seats.contains(a), hasB = seats.contains(b)
            if hasA || hasB { either += 1 }
            if hasA && hasB { both += 1 }
        }
        return either == 0 ? nil : Double(both) / Double(either)
    }
}
