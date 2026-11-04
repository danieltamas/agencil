import Foundation
import Testing
@testable import AgencilCore

/// The asking agent's project: reduced from the working directory on this Mac, stored in the local ledger only.
@Suite struct ProjectLabelTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pl-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func folder(_ parent: URL, _ names: String...) throws -> URL {
        var url = parent
        for name in names { url.appendPathComponent(name) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aSubfolderOfARepoLabelsTheRepoTopLevelWithHomeAbbreviated() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let repo = try folder(home, "Sites", "harbor-checkout")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let deep = try folder(repo, "Sources", "Pay")
        #expect(ProjectLabel.label(cwd: deep.path, home: home.path) == "harbor-checkout  ~/Sites/harbor-checkout")
        #expect(ProjectLabel.label(cwd: repo.path, home: home.path) == "harbor-checkout  ~/Sites/harbor-checkout")
    }

    @Test func aWorktreeWhoseDotGitIsAFileCountsAsARepoTop() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let tree = try folder(home, "lumen-api")
        try Data("gitdir: /elsewhere".utf8).write(to: tree.appendingPathComponent(".git"))
        let deep = try folder(tree, "src")
        #expect(ProjectLabel.label(cwd: deep.path, home: home.path) == "lumen-api  ~/lumen-api")
    }

    @Test func aFolderOutsideAnyRepoLabelsItself() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let plain = try folder(home, "notes", "weekly")
        #expect(ProjectLabel.label(cwd: plain.path, home: home.path) == "weekly  ~/notes/weekly")
    }

    @Test func aPathOutsideHomeIsKeptInFull() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let other = try scratch(); defer { try? FileManager.default.removeItem(at: other) }
        let plain = try folder(other, "ledger")
        #expect(ProjectLabel.label(cwd: plain.path, home: home.path) == "ledger  \(plain.path)")
    }

    @Test func theHomeFolderItselfIsTilde() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        #expect(ProjectLabel.label(cwd: home.path, home: home.path) == "\(home.lastPathComponent)  ~")
    }

    @Test func aSiblingWhoseNameStartsWithTheHomeNameIsNotAbbreviated() throws {
        // /x/dan is home; /x/daniel/app is somebody else's folder and must not read as "~iel/app".
        let parent = try scratch(); defer { try? FileManager.default.removeItem(at: parent) }
        let home = try folder(parent, "dan")
        let other = try folder(parent, "daniel", "app")
        let label = try #require(ProjectLabel.label(cwd: other.path, home: home.path))
        #expect(!label.contains("~iel"), "\(label)")
        #expect(label == "app  \(other.path)")
    }

    @Test func aRelativeOrEmptyDirectoryHasNoLabel() {
        #expect(ProjectLabel.label(cwd: "") == nil)
        #expect(ProjectLabel.label(cwd: "relative/dir") == nil)
    }

    @Test func theBrokerKeepsOnlyShortPrintableText() {
        #expect(ProjectLabel.clean("harbor  ~/Sites/harbor") == "harbor  ~/Sites/harbor")
        #expect(ProjectLabel.clean(String(repeating: "x", count: 300)) == String(repeating: "x", count: 300))
        #expect(ProjectLabel.clean(String(repeating: "x", count: 301)) == nil)
        #expect(ProjectLabel.clean("") == nil)
        #expect(ProjectLabel.clean(nil) == nil)
        #expect(ProjectLabel.clean(42) == nil)
        #expect(ProjectLabel.clean(["a"]) == nil)
        for bad in ["two\nlines", "bell\u{7}", "tab\there", "nul\u{0}", "esc\u{1B}[31m"] { #expect(ProjectLabel.clean(bad) == nil, "\(bad.debugDescription)") }
    }
}

@Suite struct RunOriginsMigrationTests {
    private func sqlite(_ file: URL, _ statement: String) throws -> (code: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-bail", file.path, statement]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func fresh() throws -> (dir: URL, file: URL, ledger: Ledger) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ro-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = try Ledger(directory: dir)
        try ledger.migrate()
        return (dir, dir.appendingPathComponent("agencil.sqlite"), ledger)
    }

    @Test func aNewLedgerHasRunOriginsKeyedByRunWithARequiredProject() throws {
        let (dir, file, _) = try fresh(); defer { try? FileManager.default.removeItem(at: dir) }
        let columns = try sqlite(file, "SELECT name, \"notnull\", pk FROM pragma_table_info('run_origins') ORDER BY cid;").out
        #expect(columns == "run_id|1|1\nproject|1|0\n")
        _ = try sqlite(file, "INSERT INTO runs (id, kind, status, started_at) VALUES ('th_1', 'thread', 'asking', '2030-01-01T00:00:00Z');")
        #expect(try sqlite(file, "INSERT INTO run_origins (run_id, project) VALUES ('th_1', 'harbor  ~/harbor');").code == 0)
        #expect(try sqlite(file, "INSERT INTO run_origins (run_id, project) VALUES ('th_1', 'again');").code != 0)
        #expect(try sqlite(file, "INSERT INTO run_origins (run_id, project) VALUES ('th_2', NULL);").code != 0)
    }

    @Test func migratingAgainChangesNothing() throws {
        let (dir, file, ledger) = try fresh(); defer { try? FileManager.default.removeItem(at: dir) }
        let version = try sqlite(file, "PRAGMA user_version;").out
        let schema = try sqlite(file, "SELECT type, name, sql FROM sqlite_master ORDER BY type, name;").out
        try ledger.migrate()
        try Ledger(directory: dir).migrate()
        #expect(try sqlite(file, "PRAGMA user_version;").out == version)
        #expect(try sqlite(file, "SELECT type, name, sql FROM sqlite_master ORDER BY type, name;").out == schema)
        #expect(try sqlite(file, "PRAGMA integrity_check;").out == "ok\n")
    }

    @Test func aLedgerFromBeforeTheMigrationUpgradesAndKeepsItsRows() throws {
        let (dir, file, ledger) = try fresh(); defer { try? FileManager.default.removeItem(at: dir) }
        let version = try #require(Int(try sqlite(file, "PRAGMA user_version;").out.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Put the file back to what a build before run_origins left: no table, version one lower, data present.
        _ = try sqlite(file, """
            INSERT INTO runs (id, kind, status, started_at) VALUES ('th_old', 'thread', 'answered', '2030-01-01T00:00:00Z');
            INSERT INTO threads VALUES ('th_old', 'a', 'a', 'owner', NULL, '2030-01-01T00:00:00Z');
            DROP TABLE run_origins;
            DROP TABLE thread_rounds;
            ALTER TABLE exchanges DROP COLUMN tokens_in;
            ALTER TABLE exchanges DROP COLUMN tokens_out;
            ALTER TABLE exchanges DROP COLUMN cost_usd;
            ALTER TABLE exchanges DROP COLUMN cost_basis;
            ALTER TABLE exchanges DROP COLUMN harness;
            ALTER TABLE exchanges DROP COLUMN model;
            ALTER TABLE sittings DROP COLUMN caller;
            PRAGMA user_version = \(version - 4);
            """)
        #expect(try sqlite(file, "SELECT count(*) FROM sqlite_master WHERE name = 'run_origins';").out == "0\n")
        try ledger.migrate()
        #expect(try sqlite(file, "PRAGMA user_version;").out == "\(version)\n")
        #expect(try sqlite(file, "SELECT count(*) FROM sqlite_master WHERE name = 'run_origins';").out == "1\n")
        #expect(try sqlite(file, "SELECT id, caller FROM threads;").out == "th_old|owner\n")
        #expect(try sqlite(file, "SELECT count(*) FROM run_origins;").out == "0\n")
    }

    @Test func thePositionalThreadsInsertOfEarlierFixturesStillWorks() throws {
        let (dir, file, _) = try fresh(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sqlite(file, "INSERT INTO runs (id, kind, status, started_at) VALUES ('t1', 'thread', 'answered', '2030-01-01T00:00:00Z');")
        #expect(try sqlite(file, "INSERT INTO threads VALUES ('t1', 'a', 'a', 'owner', NULL, '2030-01-01T00:00:00Z');").code == 0)
        #expect(try sqlite(file, "SELECT count(*) FROM pragma_table_info('threads');").out == "6\n")
    }
}
