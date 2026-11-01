import Foundation
import Testing
import AgencilCore

@Suite("U20 maintenance acceptance", .serialized)
struct U20MaintenanceAcceptanceTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 7_200)!
        return value
    }
    // 06:00 in the explicitly supplied calendar, 04:00 UTC.
    private var morning: Date { u14Now.addingTimeInterval(4 * 3_600) }
    private func state(_ directory: URL) throws -> [String: [String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("maintenance.json"))) as? [String: [String: Any]])
    }
    private func maintenance(_ f: U14Fixture, _ github: U14GitHub) -> Maintenance {
        Maintenance(ledger: f.ledger, directory: f.directory, github: github)
    }
    private func successes(_ count: Int) throws -> U14GitHub {
        var responses: [GitHubResponse] = []
        for _ in 0..<count { responses += try [u14Response(404), u14Response(201)] }
        return U14GitHub(responses)
    }
    private func published(_ github: U14GitHub, _ count: Int) {
        #expect(github.calls.filter { $0.method == "PUT" }.count == count)
        #expect(github.calls.filter { $0.method == "DISPATCH" }.count == count)
        #expect(github.calls.filter { $0.method == "DISPATCH" }
            .allSatisfy { $0.path == "leaderboard.yml@main" })
    }

    @Test func emptyHomePersistsPrivateStateAndRestartDoesNotRepeat() throws {
        let f = try U14Fixture(), github = U14GitHub()
        let runner = maintenance(f, github)
        #expect(runner.run(now: morning, calendar: calendar) == ["prune", "memory", "evidence", "learn"])
        let saved = try state(f.directory)
        #expect(Set(saved.keys) == ["prune", "memory", "evidence", "learn"])
        for name in ["prune", "memory", "evidence", "learn"] {
            #expect(saved[name]?["last_run"] as? Double == morning.timeIntervalSince1970)
            #expect(saved[name]?["last_attempt"] as? Double == morning.timeIntervalSince1970)
            #expect(saved[name]?["last_error"] == nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath:
            f.directory.appendingPathComponent("maintenance.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(runner.run(now: morning, calendar: calendar).isEmpty)
        #expect(maintenance(f, github).run(now: morning, calendar: calendar).isEmpty)
        #expect(github.calls.isEmpty)
    }

    @Test func intervalsIncludeExactBoundaries() throws {
        let f = try U14Fixture(), runner = maintenance(f, U14GitHub())
        #expect(runner.run(now: morning, calendar: calendar) == ["prune", "memory", "evidence", "learn"])
        #expect(runner.run(now: morning.addingTimeInterval(599), calendar: calendar).isEmpty)
        #expect(runner.run(now: morning.addingTimeInterval(600), calendar: calendar) == ["memory", "evidence"])
        #expect(runner.run(now: morning.addingTimeInterval(86_399), calendar: calendar) == ["memory", "evidence"])
        #expect(runner.run(now: morning.addingTimeInterval(86_400), calendar: calendar) == ["prune"])
        #expect(runner.run(now: morning.addingTimeInterval(7 * 86_400 - 1), calendar: calendar)
            == ["prune", "memory", "evidence"])
        #expect(runner.run(now: morning.addingTimeInterval(7 * 86_400), calendar: calendar) == ["learn"])
    }

    @Test func passActuallyPrunesAndExportsMemory() throws {
        let f = try U13Fixture()
        try f.seed(repo: f.repo)
        try f.exporter.save([f.target])
        let old = try f.file("runs/42/raw.txt", at: u13Now.addingTimeInterval(-91 * u13Day))
        try f.exchange(1, state: "answered", at: u13Now.addingTimeInterval(-91 * u13Day))
        let durable = try f.preserved()
        let runner = Maintenance(ledger: f.ledger, directory: f.directory, github: U14GitHub())
        #expect(runner.run(now: u13Now, calendar: calendar) == ["prune", "memory", "evidence", "learn"])
        #expect(!f.exists(old))
        #expect(try f.sql("SELECT question,answer FROM exchanges") == [["", "NULL"]])
        #expect(try f.preserved() == durable)
        #expect(String(decoding: try f.bytes(f.output()), as: UTF8.self).contains("# Sitting 42: review"))
    }

    @Test(arguments: ["", "0", "true", "2"])
    func leaderboardRequiresExactOptIn(_ enabled: String) throws {
        let f = try U14Fixture(settings: ["leaderboard_enabled": enabled]), github = U14GitHub()
        try f.seed()
        let runner = maintenance(f, github)
        #expect(!runner.run(now: morning, calendar: calendar).contains("leaderboard"))
        #expect(!runner.run(now: morning.addingTimeInterval(86_400), calendar: calendar).contains("leaderboard"))
        #expect(github.calls.isEmpty)
        #expect(try state(f.directory)["leaderboard"] == nil)
    }

    @Test func dailyPublishUsesLocalSixAndPersistsAcrossRestart() throws {
        let f = try U14Fixture(settings: ["leaderboard_enabled": "1"]), github = try successes(2)
        try f.seed()
        let runner = maintenance(f, github)
        #expect(runner.run(now: morning.addingTimeInterval(-60), calendar: calendar) == ["prune", "memory", "evidence", "learn"])
        #expect(github.calls.isEmpty)
        #expect(runner.run(now: morning, calendar: calendar) == ["leaderboard"])
        published(github, 1)
        #expect(runner.run(now: morning, calendar: calendar).isEmpty)
        #expect(!runner.run(now: morning.addingTimeInterval(12 * 3_600), calendar: calendar).contains("leaderboard"))
        let restarted = maintenance(f, github)
        #expect(!restarted.run(now: morning.addingTimeInterval(86_399), calendar: calendar).contains("leaderboard"))
        #expect(restarted.run(now: morning.addingTimeInterval(86_400), calendar: calendar).contains("leaderboard"))
        published(github, 2)
        #expect(try state(f.directory)["leaderboard"]?["outcomes_at_publish"] as? Int == 20)
        _ = try f.store.update { $0["leaderboard_enabled"] = "0" }
        #expect(!restarted.run(now: morning.addingTimeInterval(2 * 86_400), calendar: calendar).contains("leaderboard"))
        published(github, 2)
    }

    @Test func tenNewOutcomesRequireOneHourAndResetBaseline() throws {
        let f = try U14Fixture(settings: ["leaderboard_enabled": "1"]), github = try successes(2)
        try f.seed()
        let runner = maintenance(f, github)
        #expect(runner.run(now: morning, calendar: calendar).last == "leaderboard")
        try f.seed(9, sitting: 42)
        #expect(!runner.run(now: morning.addingTimeInterval(3_598), calendar: calendar).contains("leaderboard"))
        try f.seed(1, sitting: 43)
        // Use a fresh runner to prove the threshold is persisted, not process-local.
        let restarted = maintenance(f, github)
        #expect(!restarted.run(now: morning.addingTimeInterval(3_599), calendar: calendar).contains("leaderboard"))
        #expect(restarted.run(now: morning.addingTimeInterval(3_600), calendar: calendar).last == "leaderboard")
        published(github, 2)
        #expect(try state(f.directory)["leaderboard"]?["outcomes_at_publish"] as? Int == 30)
        #expect(!restarted.run(now: morning.addingTimeInterval(7_200), calendar: calendar).contains("leaderboard"))
        published(github, 2)
    }

    @Test func publisherFailureBacksOffWithoutBlockingOtherJobsAndSuccessClearsError() throws {
        let f = try U14Fixture(settings: ["leaderboard_enabled": "1"])
        try f.seed()
        let github = U14GitHub(try [u14Response(500), u14Response(404), u14Response(201)])
        let runner = maintenance(f, github)
        #expect(runner.run(now: morning, calendar: calendar) == ["prune", "memory", "evidence", "learn"])
        let failed = try #require(state(f.directory)["leaderboard"])
        #expect(!(try #require(failed["last_error"] as? String)).isEmpty)
        #expect(failed["last_run"] == nil)
        #expect(failed["last_attempt"] as? Double == morning.timeIntervalSince1970)
        let attempts = github.calls.count
        #expect(runner.run(now: morning.addingTimeInterval(600), calendar: calendar) == ["memory", "evidence"])
        let restarted = maintenance(f, github)
        #expect(!restarted.run(now: morning.addingTimeInterval(3_599), calendar: calendar).contains("leaderboard"))
        #expect(github.calls.count == attempts)
        #expect(restarted.run(now: morning.addingTimeInterval(3_600), calendar: calendar).contains("leaderboard"))
        let recovered = try #require(state(f.directory)["leaderboard"])
        #expect(recovered["last_error"] == nil)
        #expect(recovered["last_run"] as? Double == morning.addingTimeInterval(3_600).timeIntervalSince1970)
        #expect(recovered["last_attempt"] as? Double == morning.addingTimeInterval(3_600).timeIntervalSince1970)
        #expect(recovered["outcomes_at_publish"] as? Int == 20)
        published(github, 1)
    }

    @Test(arguments: ["not json", "[]", "{\"prune\":{\"last_run\":\"bad\"}}"])
    func corruptStateIsEmpty(_ corrupt: String) throws {
        let f = try U14Fixture(), github = U14GitHub()
        try Data(corrupt.utf8).write(to: f.directory.appendingPathComponent("maintenance.json"))
        #expect(maintenance(f, github).run(now: morning, calendar: calendar) == ["prune", "memory", "evidence", "learn"])
        #expect(try state(f.directory)["prune"]?["last_run"] as? Double == morning.timeIntervalSince1970)
        #expect(github.calls.isEmpty)
    }

    @Test func invalidConfigRunsNothingAndLeavesDataAndStateUntouched() throws {
        let f = try U13Fixture(), github = U14GitHub()
        try f.seed(repo: f.repo)
        try f.exporter.save([f.target])
        let old = try f.file("runs/old", at: .distantPast)
        try f.setting("seats", "not-json")
        let url = f.directory.appendingPathComponent("maintenance.json")
        let saved = try u14JSON(["prune": ["last_run": 1, "last_attempt": 1]])
        try saved.write(to: url)
        let runner = Maintenance(ledger: f.ledger, directory: f.directory, github: github)
        #expect(runner.run(now: morning, calendar: calendar).isEmpty)
        #expect(try Data(contentsOf: url) == saved)
        #expect(f.exists(old) && !f.exists(f.output()))
        #expect(github.calls.isEmpty)
    }

    @Test func brokerDataReportsCompletedMaintenanceViaTestSeam() throws {
        let home = try BrokerHome()
        let broker = try home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_MAINTENANCE_SECONDS": "0.1"])
        defer { broker.kill() }
        try brokerPoll {
            let reply = try home.request(["op": "data", "caller": "owner"])
            guard let data = reply["data"] as? [String: Any],
                  let jobs = data["jobs"] as? [String: [String: Any]] else { return false }
            return ["prune", "memory", "evidence", "learn"].allSatisfy { jobs[$0]?["last_run"] != nil }
        }
        let reply = try home.request(["op": "data", "caller": "owner"])
        #expect(reply["ok"] as? Bool == true)
        let data = try #require(reply["data"] as? [String: Any])
        let jobs = try #require(data["jobs"] as? [String: [String: Any]])
        let persisted = try state(home.url)
        for name in ["prune", "memory", "evidence", "learn"] {
            let job = try #require(jobs[name])
            #expect(Set(job.keys).isSubset(of: ["last_run", "last_error"]))
            #expect(job["last_run"] as? Double == persisted[name]?["last_run"] as? Double)
            #expect(try #require(job["last_run"] as? Double) > 0)
            #expect(job["last_error"] == nil)
        }
    }
}
