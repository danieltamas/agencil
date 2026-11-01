import Darwin
import Foundation
import Testing

/// U25 review round 3, finding 1 (docs/U25-SPEC.md section 2): settlement uses the plan the seat was admitted under,
/// never the config as it is by then.
@Suite(.serialized)
struct U25R3ChargeAcceptanceTests {
    private func seat(_ plan: String) -> [[String: Any]] { [u6aSeat(extra: ["plan": plan])] }

    /// Starts one held ask and writes the seat's dollar report into its run directory.
    private func heldAsk(plan: String, budgets: [[String: Any]]) throws -> U6cRig {
        let rig = try U6cRig(mode: "hold")
        try rig.configure(seat(plan), budgets: budgets)
        _ = try rig.base.data(rig.base.ask(extra: ["wait_seconds": 0]))
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.base.record.path) }
        try writeReport(rig)
        return rig
    }

    private func writeReport(_ rig: U6cRig) throws {
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
    }

    private func settled(_ rig: U6cRig) throws {
        try rig.release()
        try brokerPoll(15) { try rig.sql("SELECT count(*) FROM reservations WHERE state = 'settled';") == "1\n" }
    }

    @Test func freeSeatLaterConfiguredPaidIsStillChargedZero() throws {
        let rig = try heldAsk(plan: "free", budgets: [u6cBudget(dollars: 0, tokens: 100000)])
        try rig.configure(seat("credit"), budgets: [u6cBudget(dollars: 0, tokens: 100000)])
        try settled(rig)
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.0|11\n")
        let budget = try #require(rig.budgets().first)
        #expect(try u6cNumber(budget, "spent_dollars") == 0)
    }

    @Test func paidSeatLaterConfiguredFreeStillChargesTheReportedDollars() throws {
        let budgets = [u6cBudget(dollars: 10, tokens: 100000, hard: false)]
        let rig = try heldAsk(plan: "credit", budgets: budgets)
        try rig.configure(seat("free"), budgets: budgets)
        try settled(rig)
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.25|11\n")
        #expect(try u6cNumber(#require(rig.budgets().first), "spent_dollars") == 0.25)
    }

    // Control: with the config unreadable by settlement time a paid seat is charged as it reported.
    @Test func paidSeatWithUnreadableConfigIsChargedAsReported() throws {
        let budgets = [u6cBudget(dollars: 10, tokens: 100000, hard: false)]
        let rig = try heldAsk(plan: "credit", budgets: budgets)
        try Data("{ not json".utf8).write(to: rig.home.url.appendingPathComponent("config.json"))
        try settled(rig)
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.25|11\n")
    }

    @Test func freeSeatWithUnreadableConfigIsStillChargedZero() throws {
        let rig = try heldAsk(plan: "free", budgets: [u6cBudget(dollars: 0, tokens: 100000)])
        try Data("{ not json".utf8).write(to: rig.home.url.appendingPathComponent("config.json"))
        try settled(rig)
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.0|11\n")
    }

    @Test func freeSeatLaterConfiguredPaidIsChargedZeroWhenCrashRecoveryEndsTheExchange() throws {
        let budgets = [u6cBudget(dollars: 0, tokens: 100000)]
        let rig = try U6cRig(mode: "hold-term")
        try rig.configure(seat("free"), budgets: budgets)
        _ = try rig.base.data(rig.base.ask(extra: ["wait_seconds": 0]))
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.base.record.path) }
        let pid = try #require(rig.base.contents(".allpids").split(separator: "\n").first.flatMap { Int32($0) })
        defer { brokerGroupCleanup(pid); Darwin.kill(pid, SIGKILL) }
        try writeReport(rig)
        try rig.configure(seat("credit"), budgets: budgets)
        rig.base.broker?.kill(); _ = try rig.base.broker?.finish()
        rig.base.broker = try rig.home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_RECOVERY_HOLD": "1",
                                             "AGENCIL_PATH_PREFIX": rig.base.bin.path])
        brokerGroupCleanup(pid); Darwin.kill(pid, SIGKILL)
        try brokerPoll(12) { try u6cNumber(#require(rig.budgets().first), "reserved_tokens") == 0 }
        let after = try #require(rig.budgets().first)
        #expect(try u6cNumber(after, "spent_dollars") == 0)
        #expect(try rig.sql("SELECT basis, charged_dollars, charged_tokens FROM reservations;") == "provider|0.0|11\n")
    }
}
