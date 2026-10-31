import Foundation
import SQLite3
import CryptoKit
import Testing
import AgencilCore

let u13Now = Date(timeIntervalSince1970: 1_735_689_600)
let u13Day: TimeInterval = 86_400
struct U13FixtureError: Error { let message: String }

final class U13Fixture {
    let directory: URL
    let ledger: Ledger
    let store: ConfigStore
    private var db: OpaquePointer?
    var retention: Retention { Retention(ledger: ledger, directory: directory) }
    var exporter: MemoryExport { MemoryExport(ledger: ledger, directory: directory) }
    var repo: String { directory.appendingPathComponent("harbor/checkout").path }
    var folder: URL { directory.appendingPathComponent("memory/harbor") }
    var target: MemoryTarget { MemoryTarget(repo: repo, folder: folder.path, enabled: true) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("u13-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = try Ledger(directory: directory)
        store = ConfigStore(directory: directory)
        guard sqlite3_open(directory.appendingPathComponent("agencil.sqlite").path, &db) == SQLITE_OK else {
            throw U13FixtureError(message: "fixture open failed")
        }
        try sql("PRAGMA foreign_keys = ON")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("runs"), withIntermediateDirectories: true)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func sql(_ text: String, _ values: [String?] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let code = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
                ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard code == SQLITE_OK else { throw failure() }
        }
        var rows: [[String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL"
            })
        }
    }

    private func failure() -> U13FixtureError { .init(message: String(cString: sqlite3_errmsg(db))) }
    func setting(_ key: String, _ value: String) throws { _ = try store.update { $0[key] = value } }
    func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    func seed(_ number: Int = 42, repo: String? = nil, state: String = "done",
              body: String = "missing checkout validation", verdict: String = "repair checkout") throws {
        let id = String(number), time = stamp(u13Now.addingTimeInterval(-120 * u13Day))
        try sql("INSERT INTO briefs(id,created_at,body) VALUES(?,?,?)", [id, time, "harbor/checkout brief"])
        try sql("INSERT INTO snapshots(id,brief_id,commit_sha,created_at) VALUES(?,?,?,?)",
                [id, id, String(repeating: "a", count: 40), time])
        try sql("INSERT INTO runs(id,kind,snapshot_id,status,started_at) VALUES(?,'sitting',?,?,?)", [id, id, state, time])
        try sql("INSERT INTO sittings(id,no,council,state,round,author_vendor,snapshot_id,created_at,repo) VALUES(?,?,'review',?,'blind','harbor',?,?,?)",
                [id, id, state, id, time, repo])
        try sql("INSERT INTO seat_runs(id,run_id,seat,harness,started_at) VALUES(?,?,'maya','codex',?)", [id, id, time])
        try sql("INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at) VALUES(?,?,?,?,'defect','p1','src/cart.swift',17,?)",
                ["AG-\(id)-1", id, id, body, time])
        try sql("INSERT INTO evidence(id,claim_id,source,detail,created_at) VALUES(?,?,'fix-commit','checked',?)", [id, "AG-\(id)-1", time])
        try sql("INSERT INTO assessments(id,claim_id,seat_run_id,stance,reason,created_at) VALUES(?,?,?,'agree','jonas checked',?)",
                [id, "AG-\(id)-1", id, time])
        let minority = "[{\"claim\":\"AG-\(id)-1\",\"seat\":\"lee\",\"vendor\":\"lumen\"}]"
        try sql("INSERT INTO verdicts(id,run_id,verdict,minority,independence_flags,created_at) VALUES(?,?,?,?,?,?)",
                [id, id, verdict, minority, "[\"shared vendor\"]", time])
        try outcome(number, id: "initial-" + id, label: "confirmed")
    }

    func outcome(_ number: Int, id: String, label: String) throws {
        try sql("INSERT INTO outcomes(id,claim_id,source,certainty,label,detail,created_at) VALUES(?,?,'owner','final',?,'checked',?)",
                [id, "AG-\(number)-1", label, stamp(u13Now)])
    }

    func exchange(_ seq: Int, state: String, at: Date) throws {
        try sql("INSERT OR IGNORE INTO threads(id,requested,seat,caller,created_at) VALUES('thread','maya','maya','jonas',?)", [stamp(at)])
        try sql("INSERT INTO exchanges(thread_id,seq,question,answer,state,reason,launch_id,created_at,chain) VALUES('thread',?,'question','answer',?,'reason','launch',?,'[\"maya\"]')",
                [String(seq), state, stamp(at)])
    }

    @discardableResult
    func file(_ path: String, text: String = "raw output", at: Date) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
        return url
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func modified(_ url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }
    func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }
    func output(_ number: Int = 42) -> URL { folder.appendingPathComponent(MemoryExport.fileName(number: number)) }
    func preserved() throws -> [String: String] {
        var result: [String: String] = [:]
        for table in ["claims", "verdicts", "outcomes", "briefs", "snapshots", "sittings", "seat_runs", "evidence", "assessments"] {
            let rows = try sql("SELECT * FROM \(table) ORDER BY id")
            let data = try JSONSerialization.data(withJSONObject: rows)
            result[table] = "\(rows.count):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

func u13Refuses<T>(_ operation: () throws -> T) {
    do { _ = try operation(); Issue.record("Operation unexpectedly succeeded") } catch { }
}

// Parse fences independently: hostile lines must occur only while a fence is open.
func u13Fenced(_ text: String, contains payload: String) -> Bool {
    var fence = 0
    var blocks: [String] = []
    var lines: [String] = []
    for line in text.components(separatedBy: "\n") {
        let ticks = line.prefix { $0 == "`" }.count
        if fence == 0, ticks >= 3 {
            fence = ticks
            lines = []
        } else if fence > 0, ticks >= fence, line.dropFirst(ticks).allSatisfy({ $0 == " " }) {
            blocks.append(lines.joined(separator: "\n"))
            fence = 0
        } else if fence > 0 { lines.append(line) }
    }
    return blocks.contains { $0.contains(payload) }
}
