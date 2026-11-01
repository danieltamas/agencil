import Foundation
import Testing
import AgencilCore

@Suite("U24 commit scan acceptance", .serialized)
struct U24CommitScanAcceptanceTests {
    private func attach(_ f: U11Fixture, repo: URL, sitting: Int = 41) throws {
        try f.sql("UPDATE sittings SET repo=? WHERE id=?", [repo.path, String(sitting)])
    }
    private func state(_ f: U11Fixture) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            f.directory.appendingPathComponent("evidence-scan.json"))) as? [String: String])
    }

    // Acceptance 1: full messages, real incremental history and durable deduplication.
    @Test func fixesScanOnceAndLaterCommitsAreAdded() throws {
        let f = try U11Fixture(), id = try f.basic(), repo = try U24Git(in: f.directory)
        try attach(f, repo: repo.url)
        let first = try repo.commit("Repair guard\n\nFixes \(id)")
        let scan = CommitScan(ledger: f.ledger, directory: f.directory)
        #expect(try scan.run(now: u24Now) == 1)
        #expect(try f.sql("SELECT source,detail FROM evidence") == [["fix-commit", first]])
        #expect(try scan.run(now: u24Now) == 0)
        let second = try repo.commit("Follow-up for \(id)", at: u24Now.addingTimeInterval(1))
        #expect(try CommitScan(ledger: f.ledger, directory: f.directory).run(now:
            u24Now.addingTimeInterval(2)) == 1)
        #expect(Set(try f.book.evidence(claim: id).map(\.detail)) == [first, second])
        #expect(try state(f)[repo.url.path] == second)
        let attrs = try FileManager.default.attributesOfItem(atPath:
            f.directory.appendingPathComponent("evidence-scan.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // Acceptance 2: the revert message itself deliberately contains no claim id.
    @Test func revertResolvesOriginalMessageInSameRepository() throws {
        let f = try U11Fixture(), id = try f.basic(), repo = try U24Git(in: f.directory)
        try attach(f, repo: repo.url)
        let original = try repo.commit("Fix \(id)")
        let scan = CommitScan(ledger: f.ledger, directory: f.directory)
        _ = try scan.run(now: u24Now)
        try repo.git(["revert", "--no-edit", original], at: u24Now.addingTimeInterval(1))
        let reverted = try repo.git(["rev-parse", "HEAD"])
        #expect(try scan.run(now: u24Now.addingTimeInterval(2)) == 1)
        #expect(try f.sql("SELECT source,detail FROM evidence WHERE source='revert'") == [["revert", reverted]])
        #expect(try f.book.status(of: id, now: u24Now) == .pending)
    }

    // Acceptance 3: unusable repos cannot prevent a valid repo from being scanned.
    @Test func unknownClaimsMissingNonGitAndEmptyRepositoriesAreSkipped() throws {
        let f = try U11Fixture(), id = try f.basic(), repo = try U24Git(in: f.directory)
        try attach(f, repo: repo.url)
        _ = try repo.commit("Fix AG-999-99")
        let empty = try U24Git(in: f.directory, name: "empty")
        let plain = f.directory.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        for (offset, url) in [f.directory.appendingPathComponent("missing"), plain, empty.url].enumerated() {
            try f.sitting(42 + offset); try attach(f, repo: url, sitting: 42 + offset)
        }
        let scan = CommitScan(ledger: f.ledger, directory: f.directory)
        _ = try scan.run(now: u24Now)
        #expect(try f.book.evidence(claim: id).isEmpty)
        let sha = try repo.commit("Fix \(id)", at: u24Now.addingTimeInterval(1))
        #expect(try scan.run(now: u24Now.addingTimeInterval(2)) == 1)
        #expect(try f.sql("SELECT source,detail FROM evidence") == [["fix-commit", sha]])
    }

    // Acceptance 4: separate age and cap fixtures avoid one bound masking the other.
    @Test func firstScanExcludesCommitsOlderThanThirtyDays() throws {
        let f = try U11Fixture(), id = try f.basic(), repo = try U24Git(in: f.directory)
        try attach(f, repo: repo.url)
        let old = try repo.commit("Old fix \(id)", at: u24Now.addingTimeInterval(-31 * 86_400))
        let recent = try repo.commit("Recent fix \(id)", at: u24Now.addingTimeInterval(-29 * 86_400))
        _ = try CommitScan(ledger: f.ledger, directory: f.directory).run(now: u24Now)
        #expect(try f.sql("SELECT detail FROM evidence") == [[recent]])
        #expect(old != recent)
        #expect(try state(f)[repo.url.path] == recent)
    }

    @Test func firstScanCapsOffersAtTwoHundredAndStoresCurrentHead() throws {
        let f = try U11Fixture(), id = try f.basic(), repo = try U24Git(in: f.directory)
        try attach(f, repo: repo.url)
        var head = ""
        for index in 0..<205 {
            head = try repo.commit("Fix \(id) batch \(index)", at:
                u24Now.addingTimeInterval(Double(index - 205)))
        }
        #expect(try CommitScan(ledger: f.ledger, directory: f.directory).run(now: u24Now) == 200)
        #expect(try f.book.evidence(claim: id).count == 200)
        #expect(try state(f)[repo.url.path] == head)
    }

    // Acceptance 5: actual evidence effect, interval persistence and broker data.
    @Test func maintenanceRunsEvidenceEveryTenMinutesAndReportsIt() throws {
        let f = try U11Fixture(), id = try f.basic(), repo = try U24Git(in: f.directory)
        try attach(f, repo: repo.url)
        let sha = try repo.commit("Fix \(id)")
        let runner = Maintenance(ledger: f.ledger, directory: f.directory, github: U14GitHub())
        #expect(runner.run(now: u24Now).contains("evidence"))
        #expect(try f.sql("SELECT source,detail FROM evidence") == [["fix-commit", sha]])
        #expect(!runner.run(now: u24Now.addingTimeInterval(599)).contains("evidence"))
        #expect(runner.run(now: u24Now.addingTimeInterval(600)).contains("evidence"))
        let home = try BrokerHome()
        let broker = try home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_MAINTENANCE_SECONDS": "0.1"])
        defer { broker.kill() }
        try brokerPoll {
            let reply = try home.request(["op": "data", "caller": "owner"])
            let data = reply["data"] as? [String: Any]
            let jobs = data?["jobs"] as? [String: [String: Any]]
            return jobs?["evidence"]?["last_run"] as? Double != nil
        }
        let reply = try home.request(["op": "data", "caller": "owner"])
        #expect(reply["ok"] as? Bool == true)
        let data = try #require(reply["data"] as? [String: Any])
        let jobs = try #require(data["jobs"] as? [String: [String: Any]])
        #expect(try #require(jobs["evidence"]?["last_run"] as? Double) > 0)
        #expect(jobs["evidence"]?["last_error"] == nil)
    }
}
