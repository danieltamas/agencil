import Darwin
import Foundation
import Testing

/// U25 review round 2, finding 8 (docs/U25-SPEC.md section 2): a free seat is charged 0 dollars on every path that
/// ends an exchange, whatever its usage report says.
@Suite(.serialized)
struct U25R2ChargeAcceptanceTests {
    private func freeSeat() -> [[String: Any]] { [u6aSeat(extra: ["plan": "free"])] }
    private func zeroDollarBudget() -> [[String: Any]] { [u6cBudget(dollars: 0, tokens: 100000)] }

    @Test func freeSeatReportingDollarsIsChargedZeroOnTheNormalPath() throws {
        let rig = try U6cRig(mode: "provider")
        try rig.configure(freeSeat(), budgets: zeroDollarBudget())
        let answered = try rig.base.data(rig.base.ask())
        #expect(answered["state"] as? String == "answered")
        let budget = try #require(rig.budgets().first)
        #expect(try u6cNumber(budget, "spent_dollars") == 0)
        #expect(try u6cNumber(budget, "reserved_dollars") == 0)
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.0|11\n")
    }

    @Test func freeSeatReportingDollarsIsChargedZeroWhenCrashRecoveryEndsTheExchange() throws {
        let rig = try U6cRig(mode: "hold-term")
        try rig.configure(freeSeat(), budgets: zeroDollarBudget())
        _ = try rig.base.data(rig.base.ask(extra: ["wait_seconds": 0]))
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.base.record.path) }
        let pid = try #require(rig.base.contents(".allpids").split(separator: "\n").first.flatMap { Int32($0) })
        defer { brokerGroupCleanup(pid); Darwin.kill(pid, SIGKILL) }
        // The seat has reported a dollar spend into its run directory, then the broker dies.
        let runs = rig.home.url.appendingPathComponent("runs")
        let exchanges = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter {
            var isDirectory: ObjCBool = false
            return $0 != "preflight" && FileManager.default.fileExists(atPath: runs.appendingPathComponent($0).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        #expect(!exchanges.isEmpty)
        for name in exchanges {
            try Data("{\"dollars\":0.25,\"tokens\":11}".utf8).write(to: runs.appendingPathComponent(name + "/usage.json"))
        }
        let reserved = try u6cNumber(#require(rig.budgets().first), "reserved_tokens")
        #expect(reserved > 0)
        rig.base.broker?.kill(); _ = try rig.base.broker?.finish()
        rig.base.broker = try rig.home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_RECOVERY_HOLD": "1",
                                             "AGENCIL_PATH_PREFIX": rig.base.bin.path])
        brokerGroupCleanup(pid); Darwin.kill(pid, SIGKILL)
        try brokerPoll(12) { try u6cNumber(#require(rig.budgets().first), "reserved_tokens") == 0 }
        let after = try #require(rig.budgets().first)
        #expect(try u6cNumber(after, "spent_dollars") == 0)
        #expect(try u6cNumber(after, "reserved_dollars") == 0)
        #expect(try rig.sql(".dump runs").contains("interrupted"))
        // The seat's report was read (provider basis, its 11 tokens) and only its dollars were dropped.
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.0|11\n")
    }
}
