import Foundation

public struct LeaderboardError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { "leaderboard: \(message)" }
}

public struct LeaderboardCell: Equatable, Sendable {
    public let model: String
    public let harness: String
    public let changeKind: String
    public let n: Int
    public let confirmed: Int
    public let refuted: Int
    public let unresolved: Int
    public let confirmedShare: Double
    public let confirmedShareCI: [Double]
    public let coverage: Double?
    public let coverageCI: [Double]?
    public let goldenRecall: Double?
    public let goldenN: Int
    public let medianSeconds: Double?
    public let costPerConfirmedUSD: Double?
}

public struct LeaderboardData: Equatable, Sendable {
    public let generatedAt: String
    public let from: String
    public let to: String
    public let outcomesTotal: Int
    public let minN: Int
    public let cells: [LeaderboardCell]
}

/// The aggregate-only export. It reads counts, durations and costs; no claim text, brief, path, repo, person or host
/// reaches `LeaderboardData`, whose fields are the whole allowlist.
public enum LeaderboardExport {
    public static let schema = 1
    public static let changeKinds: Set<String> = ["auth", "schema", "ui", "refactor", "infra", "other"]
    static let floorN = 10

    private struct Key: Hashable {
        let model: String
        let harness: String
        let kind: String
    }

    private struct Tally {
        var confirmed = 0, refuted = 0, unresolved = 0
        var raised = 0, reachable = 0
        var seconds: [Double] = []
        var cost = 0.0
        var seats = Set<String>()
    }

    /// The kind is cut out of the brief inside SQLite, so the brief text itself is never read into the export.
    private static func kindsBySitting(_ ledger: Ledger) throws -> [String: String] {
        let rows = try ledger.locked {
            try ledger.query("""
                SELECT s.id,
                    CASE WHEN instr(char(10) || b.body, char(10) || 'change_kind:') = 0 THEN NULL ELSE
                        trim(substr(substr(b.body, instr(char(10) || b.body, char(10) || 'change_kind:') + 12),
                                    1, instr(substr(b.body, instr(char(10) || b.body, char(10) || 'change_kind:') + 12) || char(10), char(10)) - 1),
                             ' ' || char(9) || char(13)) END
                FROM sittings s JOIN snapshots sn ON sn.id = s.snapshot_id JOIN briefs b ON b.id = sn.brief_id;
                """, []) { row in
                let kind = Ledger.text(row, 1) ?? ""
                return (Ledger.text(row, 0) ?? "", changeKinds.contains(kind) ? kind : "other")
            }
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    /// The earliest claim time among claims that carry a confirmed or refuted outcome.
    private static func earliestDecided(_ ledger: Ledger) throws -> String? {
        try ledger.locked {
            try ledger.query("""
                SELECT MIN(c.created_at) FROM claims c
                WHERE EXISTS (SELECT 1 FROM outcomes o WHERE o.claim_id = c.id AND o.label IN ('confirmed', 'refuted'));
                """, []) { Ledger.text($0, 0) }.first ?? nil
        }
    }

    private static func publishedModel(_ model: String, aliases: [String: String], aliasesOnMain: Set<String>) -> String? {
        if PublicModels.isPublic(model) { return model }
        guard let alias = aliases[model], aliasesOnMain.contains(alias) else { return nil }
        return alias
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    private static func interval(_ successes: Int, of total: Int) -> [Double] {
        guard let bounds = Wilson.interval(successes: successes, total: total) else { return [] }
        return [rounded(bounds.lower), rounded(bounds.upper)]
    }

    public static func build(ledger: Ledger, config: SeatConfig, aliases: [String: String], aliasesOnMain: Set<String>,
                             golden: [String: GoldenScore], minN: Int, now: Date) throws -> LeaderboardData {
        let book = OutcomeBook(ledger: ledger)
        let floor = max(minN, floorN)
        let kinds = try kindsBySitting(ledger)
        let seatByName = Dictionary(config.seats.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ seat: String, sitting: String) -> Key? {
            guard let seat = seatByName[seat],
                  let model = publishedModel(seat.model, aliases: aliases, aliasesOnMain: aliasesOnMain) else { return nil }
            return Key(model: model, harness: seat.harness, kind: kinds[sitting] ?? "other")
        }

        var tallies: [Key: Tally] = [:]
        var confirmedInSitting: [String: Int] = [:]
        var confirmedBySeatSitting: [String: [String: Int]] = [:]
        var decided = 0
        try book.judged(now: now) { _, sitting, seats, status in
            if status == .confirmed { confirmedInSitting[sitting, default: 0] += 1 }
            if status == .confirmed || status == .refuted { decided += 1 }
            for seat in seats {
                if status == .confirmed { confirmedBySeatSitting[seat, default: [:]][sitting, default: 0] += 1 }
                guard let cell = key(seat, sitting: sitting) else { continue }
                switch status {
                case .confirmed: tallies[cell, default: Tally()].confirmed += 1
                case .refuted: tallies[cell, default: Tally()].refuted += 1
                case .unresolved: tallies[cell, default: Tally()].unresolved += 1
                case .pending: break
                }
            }
        }
        for run in try book.seatRuns() {
            guard let cell = key(run.seat, sitting: run.sitting) else { continue }
            tallies[cell, default: Tally()].cost += run.cost
            tallies[cell, default: Tally()].seats.insert(run.seat)
            if let seconds = run.seconds { tallies[cell, default: Tally()].seconds.append(seconds) }
            if run.valid {
                tallies[cell, default: Tally()].reachable += confirmedInSitting[run.sitting] ?? 0
                tallies[cell, default: Tally()].raised += confirmedBySeatSitting[run.seat]?[run.sitting] ?? 0
            }
        }

        let cells = tallies.compactMap { entry -> LeaderboardCell? in
            let cell = entry.key, tally = entry.value, n = tally.confirmed + tally.refuted
            guard n >= floor else { return nil }
            let times = tally.seconds.sorted(), middle = times.count / 2
            let median = times.isEmpty ? nil : (times.count % 2 == 1 ? times[middle] : (times[middle - 1] + times[middle]) / 2)
            let scores = tally.seats.compactMap { golden[$0]?.recall }
            let goldenN = scores.reduce(0) { $0 + $1.denominator }
            let goldenFound = scores.reduce(0) { $0 + $1.numerator }
            return LeaderboardCell(
                model: cell.model, harness: cell.harness, changeKind: cell.kind, n: n, confirmed: tally.confirmed,
                refuted: tally.refuted, unresolved: tally.unresolved, confirmedShare: Double(tally.confirmed) / Double(n),
                confirmedShareCI: interval(tally.confirmed, of: n),
                coverage: tally.reachable > 0 ? Double(tally.raised) / Double(tally.reachable) : nil,
                coverageCI: tally.reachable > 0 ? interval(tally.raised, of: tally.reachable) : nil,
                goldenRecall: goldenN > 0 ? Double(goldenFound) / Double(goldenN) : nil, goldenN: goldenN,
                medianSeconds: median, costPerConfirmedUSD: tally.confirmed > 0 ? tally.cost / Double(tally.confirmed) : nil)
        }.sorted { ($0.model, $0.harness, $0.changeKind) < ($1.model, $1.harness, $1.changeKind) }

        let stamp = OutcomeBook.stamp(now)
        return LeaderboardData(generatedAt: stamp, from: try earliestDecided(ledger) ?? stamp, to: stamp,
                               outcomesTotal: decided, minN: floor, cells: cells)
    }

    public static func canonicalJSON(_ data: LeaderboardData) throws -> Data {
        let cells: [[String: Any]] = data.cells.map { cell in
            var json: [String: Any] = [
                "model": cell.model, "harness": cell.harness, "change_kind": cell.changeKind, "n": cell.n,
                "confirmed": cell.confirmed, "refuted": cell.refuted, "unresolved": cell.unresolved,
                "confirmed_share": cell.confirmedShare, "confirmed_share_ci": cell.confirmedShareCI, "golden_n": cell.goldenN,
            ]
            if let value = cell.coverage { json["coverage"] = value }
            if let value = cell.coverageCI { json["coverage_ci"] = value }
            if let value = cell.goldenRecall { json["golden_recall"] = value }
            if let value = cell.medianSeconds { json["median_seconds"] = value }
            if let value = cell.costPerConfirmedUSD { json["cost_per_confirmed_usd"] = value }
            return json
        }
        let root: [String: Any] = ["schema": schema, "generated_at": data.generatedAt,
                                   "window": ["from": data.from, "to": data.to], "outcomes_total": data.outcomesTotal,
                                   "min_n": data.minN, "cells": cells]
        let body = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        // Foundation pretty-prints with 2 spaces; escape anything outside ASCII so the bytes stay plain.
        let ascii = String(decoding: body, as: UTF8.self).unicodeScalars.map { scalar -> String in
            scalar.value < 128 ? String(scalar) : String(format: "\\u%04x", scalar.value)
        }.joined()
        return Data((ascii + "\n").utf8)
    }
}
