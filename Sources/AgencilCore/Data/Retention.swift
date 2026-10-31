import Darwin
import Foundation

public struct RetentionReport: Equatable, Sendable {
    public let filesDeleted: Int
    public let bytesFreed: Int64
    public let exchangesCleared: Int
}

public struct LedgerSize: Equatable, Sendable {
    public let database: Int64
    public let rawOutputs: Int64
    public var total: Int64 { database + rawOutputs }
}

/// How long raw seat output is kept. Claims, evidence, assessments, verdicts and outcomes are never pruned.
public final class Retention: @unchecked Sendable {
    public static let defaultDays = 90
    private static let key = "retention_raw_days"

    private let ledger: Ledger
    private let directory: URL
    private let store: ConfigStore

    public init(ledger: Ledger, directory: URL) {
        self.ledger = ledger
        self.directory = directory
        store = ConfigStore(directory: directory)
    }

    private var runs: String { directory.appendingPathComponent("runs").path }

    public func days() throws -> Int {
        guard let text = try store.read().values[Self.key] else { return Self.defaultDays }
        guard let days = Int(text), String(days) == text, (1...3650).contains(days) else {
            throw DataError(message: "\(Self.key) is a whole number of days from 1 to 3650")
        }
        return days
    }

    /// Deletes raw output older than the window: regular files under `runs/` and the question and answer of finished exchanges.
    /// What a seat that is still running uses is left alone, whatever its files' dates.
    public func prune(now: Date) throws -> RetentionReport {
        let cutoff = now.addingTimeInterval(-Double(try days()) * 86_400)
        var files = 0
        var bytes: Int64 = 0
        if let root = try RunsTree.open(runs) {
            defer { close(root) }
            // Listed first, protected second: a run that starts in between is not in the list.
            let listed = try RunsTree.entries(of: root)
            _ = try RunsTree.prune(root, entries: listed, protected: try activeNames(), before: cutoff) { files += 1; bytes += $0 }
        }
        return RetentionReport(filesDeleted: files, bytesFreed: bytes, exchangesCleared: try clearExchanges(before: OutcomeBook.stamp(cutoff)))
    }

    /// The entries of `runs/` that belong to an exchange still asking or to a launch still holding its reservation.
    private func activeNames() throws -> Set<String> {
        try ledger.locked {
            var names = Set<String>()
            for (thread, seq, launch) in try ledger.query("SELECT thread_id, seq, launch_id FROM exchanges WHERE state = 'asking';", [], row: {
                (Ledger.text($0, 0) ?? "", Ledger.text($0, 1) ?? "", Ledger.text($0, 2))
            }) {
                names.insert("\(thread)-\(seq)")
                if let launch { names.insert("\(launch).log") }
            }
            for launch in try ledger.query("SELECT id FROM launches WHERE reserved = 1;", [], row: { Ledger.text($0, 0) ?? "" }) {
                names.insert("\(launch).log")
            }
            return names
        }
    }

    private func clearExchanges(before cutoff: String) throws -> Int {
        try ledger.locked {
            let finished = "state IN ('answered', 'failed') AND created_at < ? AND (answer IS NOT NULL OR question != '')"
            let count = try ledger.query("SELECT COUNT(*) FROM exchanges WHERE \(finished);", [cutoff]) { Int(Ledger.text($0, 0) ?? "") ?? 0 }.first ?? 0
            if count > 0 { try ledger.run("UPDATE exchanges SET answer = NULL, question = '' WHERE \(finished);", [cutoff]) }
            return count
        }
    }

    public func size() throws -> LedgerSize {
        var database: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            var info = stat()
            if lstat(directory.appendingPathComponent("agencil.sqlite" + suffix).path, &info) == 0 { database += Int64(info.st_size) }
        }
        var raw: Int64 = 0
        if let root = try RunsTree.open(runs) {
            defer { close(root) }
            raw = try RunsTree.size(of: root)
        }
        return LedgerSize(database: database, rawOutputs: raw)
    }
}

public struct DataError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { "data: \(message)" }
}
