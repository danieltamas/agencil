import Foundation
import SQLite3
import Testing
import AgencilCore

let u24Now = Date(timeIntervalSince1970: 1_798_761_600)
let u24Claim = "AG-41-0"

final class U24Git {
    let url: URL
    init(in directory: URL, name: String = "checkout") throws {
        url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try git(["init", "--initial-branch=main"])
    }
    @discardableResult
    func git(_ arguments: [String], at date: Date = u24Now) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = url
        process.arguments = arguments
        // Do not inherit GIT_DIR, signing, hooks, identity or the owner's configuration.
        let stamp = ISO8601DateFormatter().string(from: date)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": url.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "4", "GIT_CONFIG_KEY_0": "user.name",
            "GIT_CONFIG_VALUE_0": "Maya Harbor", "GIT_CONFIG_KEY_1": "user.email",
            "GIT_CONFIG_VALUE_1": "maya@example.invalid", "GIT_CONFIG_KEY_2": "commit.gpgsign",
            "GIT_CONFIG_VALUE_2": "false", "GIT_CONFIG_KEY_3": "core.hooksPath",
            "GIT_CONFIG_VALUE_3": "/dev/null", "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp]
        process.standardOutput = output; process.standardError = error
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let errors = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw U11FixtureError(message: String(decoding: errors, as: UTF8.self))
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func commit(_ message: String, at date: Date = u24Now) throws -> String {
        try Data(message.utf8).write(to: url.appendingPathComponent("change.txt"))
        try git(["add", "change.txt"], at: date)
        try git(["commit", "--allow-empty", "-m", message], at: date)
        return try git(["rev-parse", "HEAD"])
    }
}

func u24Fixture(evidence: Bool = true, vendors: [String] = ["harbor", "lumen", "cedar", "maple"],
                body: String = "missing check")
    throws -> U12Fixture {
    let f = try U12Fixture(members: ["maya"], vendors: vendors, extra: ["synthesizer": "jonas"])
    try f.seed(0)
    try f.sql("""
        INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at)
        VALUES(?,'41','41-maya',?,'defect','p1','src/cart.swift',1,?)
        """, [u24Claim, body, ISO8601DateFormatter().string(from: u12Now)])
    if evidence {
        try f.sql("INSERT INTO evidence(id,claim_id,source,detail,created_at) VALUES(?,?,'fix-commit',?,?)",
            ["evidence-1", u24Claim, "evidence-marker-guard", ISO8601DateFormatter().string(from: u24Now)])
    }
    return f
}

func u24Rows(_ directory: URL, _ query: String) throws -> [[String]] {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent("agencil.sqlite").path, &db,
                          SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db); throw U11FixtureError(message: "cannot open acceptance database")
    }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        throw U11FixtureError(message: String(cString: sqlite3_errmsg(db)))
    }
    var rows: [[String]] = []
    while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return rows }
        guard code == SQLITE_ROW else { throw U11FixtureError(message: String(cString: sqlite3_errmsg(db))) }
        rows.append((0..<sqlite3_column_count(statement)).map {
            sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL"
        })
    }
}

func u24Adjudicate(_ rig: U23Rig, id: String = u24Claim, caller: String = "owner") throws -> [String: Any] {
    try rig.home.request(["op": "adjudicate", "id": id, "caller": caller, "wait_seconds": 5])
}
