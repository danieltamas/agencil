import Darwin
import Foundation
import Testing
import AgencilCore

@Suite struct CoreRegressionTests {
    @Test func textWithEmbeddedNulRoundTripsWhole() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let ledger = try Ledger(directory: temp.url)
        let claim = try ledger.appendClaim(body: "before\0after")
        #expect(try ledger.claim(id: claim.id)?.body == "before\0after")
    }

    @Test func insertOrReplaceCannotOverwriteAClaim() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let ledger = try Ledger(directory: temp.url)
        let claim = try ledger.appendClaim(body: "original")
        let file = temp.url.appendingPathComponent("agencil.sqlite").path
        let (status, _) = try acceptanceCommand([
            "/usr/bin/sqlite3", file,
            "INSERT OR REPLACE INTO claims (id, body, created_at) VALUES ('\(claim.id)', 'replaced', 'now');"])
        #expect(status != 0)
        #expect(try ledger.claim(id: claim.id)?.body == "original")
    }

    @Test func claimCannotBeReplacedThroughItsRowid() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let ledger = try Ledger(directory: temp.url)
        let claim = try ledger.appendClaim(body: "original")
        let file = temp.url.appendingPathComponent("agencil.sqlite").path
        let (status, _) = try acceptanceCommand([
            "/usr/bin/sqlite3", file,
            "INSERT OR REPLACE INTO claims (rowid, id, body, created_at) VALUES (1, 'other', 'replaced', 'now');"])
        #expect(status != 0)
        #expect(try ledger.claim(id: claim.id)?.body == "original")
    }

    @Test(.timeLimit(.minutes(1))) func fifoAtTheConfigPathIsRefusedNotWaitedOn() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        #expect(mkfifo(temp.url.appendingPathComponent("config.json").path, 0o600) == 0)
        #expect(throws: (any Error).self) { _ = try ConfigStore(directory: temp.url).update { $0["a"] = "b" } }
    }

    @Test func manyConnectionsMigratingAFreshLedgerAllSucceed() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let failures = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { _ = try Ledger(directory: temp.url) } catch { failures.increment() }
        }
        #expect(failures.value == 0)
    }

    @Test func maximumRevisionIsAVisibleErrorNotACrash() throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let file = temp.url.appendingPathComponent("config.json")
        let bytes = Data("{\"revision\": \(Int64.max), \"values\": {}}".utf8)
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { _ = try ConfigStore(directory: temp.url).update { $0["a"] = "b" } }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func processLeftByASuccessfulLeaderIsKilledWithItsGroup() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let pidFile = temp.url.appendingPathComponent("pid")
        let result = try await ProcessRunner().run(
            ["/bin/sh", "-c", "/bin/sleep 30 & echo $! > \"$1\"", "fixture", pidFile.path],
            timeout: .seconds(5), gracePeriod: .milliseconds(100))
        #expect(result.status == 0)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
