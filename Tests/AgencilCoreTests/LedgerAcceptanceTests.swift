// API contract: Ledger(directory: URL) throws; migrate() throws (also safe after init).
// appendClaim(body: String, superseding: String? = nil) throws -> Ledger.Claim;
// claim(id: String) throws -> Ledger.Claim?; Claim has id: String, body: String,
// supersedes: String?. Init opens agencil.sqlite; migrate installs numbered migrations.
// SQLite inspection uses the system CLI, independently of Ledger's read API.
import Foundation
import Testing
import AgencilCore

@Suite struct LedgerAcceptanceTests {
    private let tables: Set<String> = [
        "briefs", "snapshots", "configs", "runs", "seat_runs", "requests", "claims",
        "evidence", "assessments", "verdicts", "outcomes", "proposals"
    ]

    @Test func emptyFileMigratesAndSecondMigrationChangesNothing() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let file = temp.url.appendingPathComponent("agencil.sqlite")
        try Data().write(to: file)
        let ledger = try Ledger(directory: temp.url)
        try ledger.migrate()
        let version = try query(file, "PRAGMA user_version;")
        #expect((Int(version.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0)
        let names = try query(file, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
        let actual = Set(names.split(separator: "\n").map(String.init))
        #expect(tables.isSubset(of: actual))
        let schema = try query(file, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name;")
        #expect(try query(file, "PRAGMA integrity_check;") == "ok\n")
        try ledger.migrate()
        #expect(try query(file, "PRAGMA user_version;") == version)
        #expect(try query(file, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;") == names)
        #expect(try query(file, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name;") == schema)
        let reopened = try Ledger(directory: temp.url)
        try reopened.migrate()
        #expect(try query(file, "PRAGMA user_version;") == version)
        let header = try Data(contentsOf: file).prefix(16)
        #expect(header == Data("SQLite format 3\0".utf8))
    }

    @Test func hostileTextRoundTripsAsDataAndSurvivesReopen() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let ledger = try Ledger(directory: temp.url)
        try ledger.migrate()
        let body = "maya's claim'); DROP TABLE claims; --\nsecond line"
        let inserted = try ledger.appendClaim(body: body)
        #expect(inserted.body == body)
        let reopened = try Ledger(directory: temp.url)
        let saved = try #require(try reopened.claim(id: inserted.id))
        #expect(saved.body == body)
        #expect(saved.id == inserted.id)
        let file = temp.url.appendingPathComponent("agencil.sqlite")
        #expect(try query(file, "SELECT count(*) FROM claims;") == "1\n")
        let actual = Set(try query(file, "SELECT name FROM sqlite_master WHERE type='table';")
            .split(separator: "\n").map(String.init))
        #expect(tables.isSubset(of: actual))
    }

    @Test func editingAppendsSupersedingRowAndKeepsOriginalReadable() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let ledger = try Ledger(directory: temp.url)
        try ledger.migrate()
        let original = try ledger.appendClaim(body: "Initial claim")
        let revised = try ledger.appendClaim(body: "Corrected claim", superseding: original.id)
        #expect(revised.id != original.id)
        #expect(revised.supersedes == original.id)
        let reopened = try Ledger(directory: temp.url)
        let old = try #require(try reopened.claim(id: original.id))
        let new = try #require(try reopened.claim(id: revised.id))
        #expect(old.body == "Initial claim")
        #expect(old.supersedes == nil)
        #expect(new.body == "Corrected claim")
        #expect(new.supersedes == original.id)
        #expect(try query(temp.url.appendingPathComponent("agencil.sqlite"),
                          "SELECT count(*) FROM claims;") == "2\n")
    }

    private func query(_ file: URL, _ sql: String) throws -> String {
        let (status, output) = try acceptanceCommand(["/usr/bin/sqlite3", file.path, sql])
        try #require(status == 0, "Independent SQLite inspection failed")
        return output
    }
}
