import Foundation
import SQLite3
import Testing
import AgencilCore

let u14Now = Date(timeIntervalSince1970: 1_735_689_600)
let u14Root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
struct U14Error: Error { let message: String }

func u14JSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
func u14Object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
func u14Refuses<T>(_ operation: () throws -> T) {
    do { _ = try operation(); Issue.record("Expected rejection") } catch { }
}

final class U14GitHub: GitHubClient, @unchecked Sendable {
    struct Call { let method: String; let path: String; let body: Data? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var responses: [GitHubResponse]
    init(_ responses: [GitHubResponse] = []) { self.responses = responses }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func request(_ method: String, _ path: String, _ body: Data? = nil) throws -> GitHubResponse {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(method: method, path: path, body: body))
        guard !responses.isEmpty else { throw U14Error(message: "Unscripted request") }
        return responses.removeFirst()
    }
    func get(_ path: String) throws -> GitHubResponse { try request("GET", path) }
    func put(_ path: String, body: Data) throws -> GitHubResponse { try request("PUT", path, body) }
    func dispatch(workflow: String, ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(method: "DISPATCH", path: workflow + "@" + ref, body: nil))
    }
}
func u14Response(_ status: Int, _ object: [String: Any] = [:]) throws -> GitHubResponse {
    GitHubResponse(status: status, body: try u14JSON(object))
}

final class U14Fixture {
    let directory: URL
    let ledger: Ledger
    let store: ConfigStore
    private var db: OpaquePointer?
    init(models: [String] = ["gpt-5.x-codex"], settings: [String: String] = [:]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("u14-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = try Ledger(directory: directory)
        store = ConfigStore(directory: directory)
        let seats = zip(["maya", "jonas", "lee"], models).map {
            ["name": $0.0, "harness": "codex", "model": $0.1, "vendor": "harbor"]
        }
        let text = String(decoding: try u14JSON(seats), as: UTF8.self)
        _ = try store.update { $0 = settings.merging(["seats": text]) { _, new in new } }
        guard sqlite3_open(directory.appendingPathComponent("agencil.sqlite").path, &db) == SQLITE_OK else {
            throw U14Error(message: "Cannot open fixture")
        }
        try sql("PRAGMA foreign_keys = ON")
    }
    deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: directory) }
    func sql(_ text: String, _ values: [String?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let code = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
                ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard code == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func failure() -> U14Error { .init(message: String(cString: sqlite3_errmsg(db))) }
    func seed(_ n: Int = 20, confirmed: Int = 10, unresolved: Int = 0,
              sitting: Int = 41, seat: String = "maya", kind: String = "auth",
              exit: Int = 0, seconds: Int = 10, cost: Double = 2,
              brief: String? = nil, lineOffset: Int = 0, pendingClaimAt: String? = nil) throws {
        let id = String(sitting), time = "2024-12-01T00:00:00Z"
        try sql("INSERT INTO briefs(id,created_at,body) SELECT ?,?,? WHERE NOT EXISTS (SELECT 1 FROM sittings WHERE id=?)",
                [id, time, brief ?? "harbor/checkout\nchange_kind: \(kind)\nprivate prompt", id])
        try sql("INSERT INTO snapshots(id,brief_id,commit_sha,created_at) SELECT ?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM sittings WHERE id=?)",
                [id, id, String(repeating: "a", count: 40), time, id])
        try sql("INSERT INTO runs(id,kind,snapshot_id,status,started_at,ended_at) SELECT ?,'sitting',?,'done',?,? WHERE NOT EXISTS (SELECT 1 FROM sittings WHERE id=?)",
                [id, id, time, time, id])
        try sql("INSERT INTO sittings(id,no,council,state,round,author_vendor,snapshot_id,created_at) SELECT ?,?, 'review','done','blind','harbor',?,? WHERE NOT EXISTS (SELECT 1 FROM sittings WHERE id=?)",
                [id, id, id, time, id])
        let end = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_733_011_200 + Double(seconds)))
        try sql("INSERT INTO seat_runs(id,run_id,seat,harness,started_at,ended_at,cost_usd,exit_code) VALUES(?,?,?,'codex',?,?,?,?)",
                [id + seat, id, seat, time, end, String(cost), String(exit)])
        for k in 0..<(n + unresolved + (pendingClaimAt == nil ? 0 : 1)) {
            let claim = id + seat + String(k)
            try sql("INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at) VALUES(?,?,?,'private claim text','defect','p1','src/private.swift',?,?)",
                    [claim, id, id + seat, String(k * 20 + 1 + lineOffset),
                     k == n + unresolved ? pendingClaimAt : time])
            if k < n {
                try sql("INSERT INTO outcomes(id,claim_id,source,adjudicator,certainty,label,detail,created_at) VALUES(?,?,'adjudication','lee','high',?,'checked',?)",
                        [claim, claim, k < confirmed ? "confirmed" : "refuted", time])
            }
        }
    }
    func build(minN: Int = 20, aliases: [String: String] = [:], approved: Set<String> = [],
               golden: [String: GoldenScore] = [:]) throws -> LeaderboardData {
        try LeaderboardExport.build(ledger: ledger, config: SeatConfig(values: store.read().values),
                                    aliases: aliases, aliasesOnMain: approved, golden: golden, minN: minN, now: u14Now)
    }
    func publisher(_ github: U14GitHub) -> LeaderboardPublisher {
        LeaderboardPublisher(ledger: ledger, directory: directory, github: github)
    }
}
