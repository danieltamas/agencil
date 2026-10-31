import Foundation
import SQLite3
import Testing
import AgencilCore

let u11Epoch = Date(timeIntervalSince1970: 1_735_689_600)
func u11Date(_ days: Double) -> Date { u11Epoch.addingTimeInterval(days * 86_400) }
struct U11FixtureError: Error { let message: String }

final class U11Fixture {
    let directory: URL
    let ledger: Ledger
    let book: OutcomeBook
    private var db: OpaquePointer?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("u11-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ledger = try Ledger(directory: directory)
        book = OutcomeBook(ledger: ledger)
        guard sqlite3_open(directory.appendingPathComponent("agencil.sqlite").path, &db) == SQLITE_OK else {
            throw U11FixtureError(message: "fixture open failed")
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

    private func failure() -> U11FixtureError { .init(message: String(cString: sqlite3_errmsg(db))) }
    func stamp(_ days: Double) -> String { ISO8601DateFormatter().string(from: u11Date(days)) }

    func sitting(_ number: Int = 41, council: String = "review") throws {
        let id = String(number), time = stamp(0)
        try sql("INSERT INTO briefs(id,created_at,body) VALUES(?,?,?)", [id, time, "harbor/checkout"])
        try sql("INSERT INTO snapshots(id,brief_id,commit_sha,created_at) VALUES(?,?,?,?)", [id, id, String(repeating: "a", count: 40), time])
        try sql("INSERT INTO runs(id,kind,snapshot_id,status,started_at,ended_at) VALUES(?,'sitting',?,'done',?,?)", [id, id, time, time])
        try sql("INSERT INTO sittings(id,no,council,state,round,author_vendor,snapshot_id,created_at) VALUES(?,?,?,'done','blind','harbor',?,?)", [id, id, council, id, time])
    }

    func seat(_ name: String = "maya", sitting: Int = 41, exit: Int? = 0, cost: Double = 1, seconds: Int = 10) throws {
        try sql("INSERT INTO seat_runs(id,run_id,seat,harness,started_at,ended_at,cost_usd,exit_code) VALUES(?,?,?,'codex',?,?,?,?)",
                ["\(sitting)-\(name)", String(sitting), name, stamp(0),
                 ISO8601DateFormatter().string(from: u11Epoch.addingTimeInterval(Double(seconds))),
                 String(cost), exit.map(String.init)])
    }

    func claim(_ k: Int = 3, sitting: Int = 41, seat: String = "maya", line: Int = 10, days: Double = 0) throws -> String {
        let id = "AG-\(sitting)-\(k)"
        try sql("INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at) VALUES(?,?,?,'missing check','defect','p1','src/cart.swift',?,?)",
                [id, String(sitting), "\(sitting)-\(seat)", String(line), stamp(days)])
        return id
    }

    func evidence(_ claim: String, days: Double = 0) throws {
        try sql("INSERT INTO evidence(id,claim_id,source,detail,created_at) VALUES(?,?,'fix-commit','sha',?)", [UUID().uuidString, claim, stamp(days)])
    }

    func outcome(_ claim: String, label: String, days: Double = 0, source: String = "adjudication") throws {
        try sql("INSERT INTO outcomes(id,claim_id,source,adjudicator,certainty,label,detail,created_at) VALUES(?,?,?,'lee','high',?,'checked',?)",
                [UUID().uuidString, claim, source, label, stamp(days)])
    }

    func basic() throws -> String {
        try sitting(); try seat(); return try claim()
    }
}

func u11Seat(_ name: String, vendor: String) throws -> Seat {
    let data = try JSONSerialization.data(withJSONObject: [["name": name, "harness": "codex", "model": "demo", "vendor": vendor]])
    return try #require(SeatConfig(values: ["seats": String(decoding: data, as: UTF8.self)]).seats.first)
}

func u11Rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
