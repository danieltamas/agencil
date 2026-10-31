import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U6cCapacityAcceptanceTests {
    @Test func parkedAncestorsReleaseSeatSlotAndChainChargesRootCumulatively() throws {
        let rig = try U6bRig(["codex": "cli:b", "claude": "cli:c"])
        try rig.base.config(seats: [u6aSeat("a"), u6aSeat("b", "claude"), u6aSeat("c", "hermes")],
                            routes: ["a", "b", "c"].map { u6aRoute($0, callers: ["owner", "a", "b"]) },
                            raw: ["agent_access": "on", "limits": "{\"seats_at_once\":1,\"process_cap\":4}",
                                  "budgets": u6aText([u6cBudget(scope: "root", key: "owner", tokens: 100000)])])
        let d = try rig.root()
        #expect((d["answer"] as? String)?.contains("u6b hermes") == true)
        #expect(try rig.read("events").split(separator: "\n").count == 3)
        let envelope = try rig.base.data(rig.home.request(["op": "budgets"]))
        let rows = try #require(envelope["budgets"] as? [[String: Any]])
        let b = try #require(rows.first)
        let costs = try [d, rig.data("codex"), rig.data("claude")].map {
            try u6cNumber(#require($0["cost"] as? [String: Any]), "tokens")
        }
        #expect(try u6cNumber(b, "spent_tokens") == costs.reduce(0, +))
        #expect(try u6cNumber(b, "reserved_tokens") == 0)
    }

    @Test func processCapRefusesNestedAskImmediatelyWhileAncestorsAreParked() throws {
        let rig = try U6bRig(["codex": "cli:b", "claude": "cli:c"])
        try rig.base.config(seats: [u6aSeat("a"), u6aSeat("b", "claude"), u6aSeat("c", "hermes")],
                            routes: ["a", "b", "c"].map { u6aRoute($0, callers: ["owner", "a", "b"]) },
                            raw: ["agent_access": "on", "limits": "{\"seats_at_once\":1,\"process_cap\":2}"])
        let start = Date(); _ = try rig.root()
        #expect(Date().timeIntervalSince(start) < 5)
        try rig.refusal("claude", "refused: busy")
        #expect(try rig.read("events").split(separator: "\n").count == 2)
        #expect(try rig.sql("SELECT count(*) FROM runs; SELECT count(*) FROM requests;") == "2\n3\n")
        #expect(try rig.sql(".dump requests").split(separator: "\n").filter {
            $0.hasPrefix("INSERT INTO") && $0.contains("refused")
        }.count == 1)
    }

    @Test func occupiedSeatRefusesZeroWaitTimesOutAndSucceedsWhenReleasedWithinWait() throws {
        let rig = try U6cRig(mode: "hold")
        try rig.configure(limits: ["seats_at_once": 1, "process_cap": 4])
        let first = try rig.base.data(rig.base.ask(extra: ["wait_seconds": 0]))
        let thread = try #require(first["thread"] as? String)
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.base.record.path) }
        var start = Date()
        rig.base.refused(try rig.base.ask(extra: ["wait_seconds": 0]), "refused: busy", exit: 3)
        #expect(Date().timeIntervalSince(start) < 1)
        start = Date()
        let (code, _, err) = try rig.home.cli(["ask", "primary", "other", "--wait", "1"])
        #expect(code == 3); #expect(err.contains("refused: busy"))
        #expect(Date().timeIntervalSince(start) >= 0.8)
        let pending = try BrokerProcess(["ask", "primary", "waiter", "--wait", "10", "--json"], home: rig.home.url)
        usleep(200_000); try rig.release()
        let result = try pending.finish(); #expect(result.0 == 0)
        _ = try rig.base.cliData(["result", thread, "--wait", "10"])
    }

    @Test func memoryFloorRefusesWithoutRunAndLowerFloorAllowsExecution() throws {
        let rig = try U6cRig(memory: 100)
        try rig.configure(limits: ["memory_floor_mb": 500])
        try rig.refusedWithoutRun("memory")
        try rig.configure(limits: ["memory_floor_mb": 50])
        _ = try rig.base.answered(rig.base.ask())
    }

    @Test func durableReservationSurvivesRestartUntilProcessGroupDiesThenChargesInterruptedRun() throws {
        let rig = try U6cRig(mode: "hold-term")
        try rig.configure(budgets: [u6cBudget(tokens: 100000)])
        _ = try rig.base.data(rig.base.ask(extra: ["wait_seconds": 0]))
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.base.record.path) }
        let before = try #require(rig.budgets().first)
        let reserved = try u6cNumber(before, "reserved_tokens"); #expect(reserved > 0)
        let text = try rig.base.contents(".allpids")
        let pid = try #require(text.split(separator: "\n").first.flatMap { Int32($0) })
        // The stub ignores recovery's TERM; the recovery seam defers KILL.
        defer { brokerGroupCleanup(pid); Darwin.kill(pid, SIGKILL) }
        rig.base.broker?.kill(); _ = try rig.base.broker?.finish()
        rig.base.broker = try rig.home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_RECOVERY_HOLD": "1",
                                             "AGENCIL_PATH_PREFIX": rig.base.bin.path])
        #expect(brokerAlive(pid))
        #expect(try u6cNumber(#require(rig.budgets().first), "reserved_tokens") == reserved)
        brokerGroupCleanup(pid); Darwin.kill(pid, SIGKILL)
        try brokerPoll(12) { try u6cNumber(#require(rig.budgets().first), "reserved_tokens") == 0 }
        let after = try #require(rig.budgets().first)
        #expect(try u6cNumber(after, "spent_tokens") == reserved)
        #expect(try rig.sql(".dump runs").contains("interrupted"))
    }
}
