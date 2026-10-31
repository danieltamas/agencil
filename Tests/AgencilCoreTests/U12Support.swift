import Foundation
import SQLite3
import Testing
import AgencilCore

let u12Now = Date(timeIntervalSince1970: 1_735_689_600)
struct U12FixtureError: Error { let message: String }

// Independent SQL fixtures, copied in shape from U11Support, not its scoring logic.
final class U12Fixture {
    let directory: URL
    let ledger: Ledger
    let store: ConfigStore
    let loop: LearnLoop
    private var db: OpaquePointer?

    init(members: [String] = ["maya", "jonas", "lee"],
         vendors: [String] = ["harbor", "lumen", "cedar", "maple"],
         extra: [String: Any] = [:]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("u12-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = try Ledger(directory: directory)
        store = ConfigStore(directory: directory)
        loop = LearnLoop(ledger: ledger, directory: directory)
        let seats = zip(["maya", "jonas", "lee", "rory"], vendors).map {
            ["name": $0.0, "harness": "codex", "model": "demo", "vendor": $0.1]
        }
        let council: [String: Any] = ["name": "review", "seats": members,
            "rule": "majority", "rounds": ["rebuttal": false], "deadline_seconds": 30]
            .merging(extra) { _, new in new }
        let seatText = try u12JSON(seats), councilText = try u12JSON([council])
        _ = try store.update {
            $0 = ["seats": seatText, "councils": councilText, "routes": "[]",
                  "unrelated": "retain exact value\nwith whitespace", "agent_access": "off"]
        }
        guard sqlite3_open(directory.appendingPathComponent("agencil.sqlite").path, &db) == SQLITE_OK else {
            throw U12FixtureError(message: "fixture open failed")
        }
        try sql("PRAGMA foreign_keys = ON")
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
            let code: Int32
            if let value { code = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            else { code = sqlite3_bind_null(statement, Int32(index + 1)) }
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

    private func failure() -> U12FixtureError { .init(message: String(cString: sqlite3_errmsg(db))) }

    func seed(_ n: Int, confirmed: Int = 0, seat: String = "maya", sitting: Int = 41,
              council: String = "review", participants: [String]? = nil) throws {
        let id = String(sitting), time = ISO8601DateFormatter().string(from: u12Now)
        try sql("INSERT INTO briefs(id,created_at,body) VALUES(?,?,?)", [id, time, "harbor/checkout"])
        try sql("INSERT INTO snapshots(id,brief_id,commit_sha,created_at) VALUES(?,?,?,?)",
                [id, id, String(repeating: "a", count: 40), time])
        try sql("INSERT INTO runs(id,kind,snapshot_id,status,started_at,ended_at) VALUES(?,'sitting',?,'done',?,?)",
                [id, id, time, time])
        try sql("INSERT INTO sittings(id,no,council,state,round,author_vendor,snapshot_id,created_at) VALUES(?,?,?,'done','blind','harbor',?,?)",
                [id, id, council, id, time])
        for name in participants ?? [seat] {
            try sql("INSERT INTO seat_runs(id,run_id,seat,harness,started_at,ended_at,cost_usd,exit_code) VALUES(?,?,?,'codex',?,?,1,0)",
                    [id + "-" + name, id, name, time, time])
        }
        for k in 0..<n {
            let claim = "AG-\(sitting)-\(k)"
            try sql("INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at) VALUES(?,?,?,'missing check','defect','p1','src/cart.swift',?,?)",
                    [claim, id, id + "-" + seat, String(k * 10 + 1), time])
            try sql("INSERT INTO outcomes(id,claim_id,source,adjudicator,certainty,label,detail,created_at) VALUES(?,?,'adjudication','lee','high',?,'checked',?)",
                    [UUID().uuidString, claim, k < confirmed ? "confirmed" : "refuted", time])
        }
    }

    func bytes() throws -> Data { try Data(contentsOf: directory.appendingPathComponent("config.json")) }
    func config() throws -> SeatConfig { try SeatConfig(values: store.read().values) }
    func seat(_ name: String) throws -> Seat { try #require(try config().seat(named: name)) }
    func councilBody() throws -> String { try #require(try store.read().values["councils"]) }
    func councilObject() throws -> [String: Any] {
        let array = try JSONSerialization.jsonObject(with: Data(councilBody().utf8)) as? [[String: Any]]
        return try #require(array?.first)
    }
    func propose(candidates: [Seat] = [], ideas: [PromptIdea] = []) throws -> [Proposal] {
        try loop.propose(now: u12Now, candidates: candidates, ideas: ideas)
    }
    func drop() throws -> Proposal { try #require(try propose().first { $0.kind == .dropSeat }) }
    func reviewed(_ proposal: Proposal, verdict: ReviewVerdict = .endorse) throws {
        let reviewer = try #require(try loop.reviewer(for: proposal.id))
        try loop.review(proposal.id, by: reviewer, verdict: verdict, note: "checked evidence", at: u12Now)
    }
}

func u12JSON(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

// Wilson score interval derived directly from the binomial formula, independent of Share.
func u12Wilson(_ successes: Int, _ total: Int) -> (lower: Double, upper: Double) {
    let z = 1.96, n = Double(total), p = Double(successes) / Double(total)
    let denominator = 1 + z * z / n
    let center = (p + z * z / (2 * n)) / denominator
    let radius = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
    return (max(0, center - radius), min(1, center + radius))
}

func u12Refuses<T>(_ operation: () throws -> T) {
    do { _ = try operation(); Issue.record("Operation unexpectedly succeeded") }
    catch { }
}
