import Foundation
import Testing

@Suite(.serialized)
struct U6bChainAcceptanceTests {
    @Test(arguments: ["cli", "stripped", "mcp"])
    func threeSeatsSucceedAtTwoHopsAndFourthAskIsRefusedWithoutRun(mode: String) throws {
        let rig = try U6bRig(["codex": mode + ":b", "claude": mode + ":c", "hermes": mode + ":d"])
        let root = try rig.root()
        rig.chain(root, ["a"])
        #expect((root["answer"] as? String)?.contains("refused: hop limit") == true)
        if mode == "mcp" {
            for (kind, seats) in [("codex", ["a", "b"]), ("claude", ["a", "b", "c"])] {
                let lines = try rig.read(kind + ".out").split(separator: "\n")
                let reply = try brokerJSON(Data(try #require(lines.last).utf8))
                let result = try #require(reply["result"] as? [String: Any])
                #expect(result["isError"] as? Bool == false)
                let envelope = try #require(result["structuredContent"] as? [String: Any])
                rig.chain(try #require(envelope["data"] as? [String: Any]), seats)
            }
            let lines = try rig.read("hermes.out").split(separator: "\n")
            let reply = try brokerJSON(Data(try #require(lines.last).utf8))
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let envelope = try #require(result["structuredContent"] as? [String: Any])
            let data = try #require(envelope["data"] as? [String: Any])
            #expect(data["reason"] as? String == "refused: hop limit")
        } else {
            rig.chain(try rig.data("codex"), ["a", "b"])
            rig.chain(try rig.data("claude"), ["a", "b", "c"])
            try rig.refusal("hermes", "refused: hop limit")
        }
        #expect(try rig.read("events").split(separator: "\n").count == 3)
        // One refused request, with no fourth run. Inspect through the real sqlite CLI.
        #expect(try rig.sql("SELECT count(*) FROM runs; SELECT count(*) FROM requests;") == "3\n4\n")
        let dump = try rig.sql(".dump requests")
        #expect(dump.split(separator: "\n").filter { $0.hasPrefix("INSERT INTO") && $0.contains("refused") }.count == 1)
    }

    @Test(arguments: [2, 4])
    func cycleIsCheckedBeforeHopLimit(limit: Int) throws {
        let rig = try U6bRig(["codex": "cli:b", "claude": "cli:c", "hermes": "cli:a"], limit: limit)
        _ = try rig.root()
        try rig.refusal("hermes", "refused: cycle a -> b -> c -> a")
        #expect(try rig.read("events").split(separator: "\n").count == 3)
    }

    @Test func anotherLiveRunsCapabilityDoesNotMatchDescendant() throws {
        let rig = try U6bRig(["codex": "replace:b", "hermes": "hold:"])
        let pending = try rig.base.data(rig.base.ask("c", extra: ["wait_seconds": 0]))
        let thread = try #require(pending["thread"] as? String)
        try brokerPoll(12) { (try? rig.read("hermes.cap").count) == 64 }
        _ = try rig.root()
        try rig.refusal("codex", "refused: capability does not match caller")
        #expect(!FileManager.default.fileExists(atPath: rig.record + ".claude.cap"))
        try Data().write(to: URL(fileURLWithPath: rig.record + ".release"))
        _ = try rig.base.cliData(["result", thread, "--wait", "10"])
    }

    @Test func endedAndInventedCapabilitiesExpireOverSocketAndCLIAndNeverPersistInClear() throws {
        let rig = try U6bRig(["codex": "cli:b"])
        _ = try rig.root()
        let a = try rig.read("codex.cap"), b = try rig.read("claude.cap")
        for cap in [a, b] {
            #expect(cap.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        }
        #expect(a != b)
        for cap in [a, String(repeating: "f", count: 64)] {
            rig.base.refused(try rig.home.request(["op": "ask", "caller": "owner", "target": "c",
                                                   "question": "replay", "cap": cap]),
                             "refused: capability expired", exit: 3)
            let (code, _, err) = try rig.home.cli(["ask", "c", "replay"], env: ["AGENCIL_CAP": cap])
            #expect(code == 3)
            #expect(err.trimmingCharacters(in: .whitespacesAndNewlines) == "agencil: refused: capability expired")
        }
        #expect(!FileManager.default.fileExists(atPath: rig.record + ".hermes.cap"))
        let bytes = try Data(contentsOf: rig.home.url.appendingPathComponent("agencil.sqlite"))
        let dump = try rig.sql(".dump")
        for cap in [a, b] {
            #expect(bytes.range(of: Data(cap.utf8)) == nil)
            #expect(!dump.contains(cap))
            let grep = try BrokerProcess(["-a", "-F", cap, rig.home.url.appendingPathComponent("agencil.sqlite").path],
                                         home: rig.home.url, executable: URL(fileURLWithPath: "/usr/bin/grep"))
            #expect(try grep.finish().0 == 1)
        }
    }

    @Test(arguments: ["cli", "mcp"])
    func descendantClaimingOwnerUsesParentSeatRoute(mode: String) throws {
        let rig = try U6bRig(["codex": mode + ":b"], callers: ["owner"])
        let root = try rig.root()
        #expect((root["answer"] as? String)?.contains("refused: no route from a to b") == true)
        #expect(!FileManager.default.fileExists(atPath: rig.record + ".claude.cap"))
        try rig.base.config(seats: [u6aSeat("a"), u6aSeat("b", "claude")],
                            routes: [u6aRoute("a"), u6aRoute("b", callers: ["a"])], raw: ["agent_access": "on"])
        let allowed = try rig.root()
        #expect((allowed["answer"] as? String)?.contains("u6b claude") == true)
    }

    @Test func detachedProcessWithoutCapabilityIsNewRootAtExhaustedDepth() throws {
        let rig = try U6bRig(["codex": "cli:b", "claude": "cli:c", "hermes": "detached:b"])
        _ = try rig.root()
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.record + ".detached.exit") }
        #expect(try rig.read("detached.exit") == "0")
        let envelope = try brokerJSON(Data(rig.read("detached.out").utf8))
        rig.chain(try #require(envelope["data"] as? [String: Any]), ["b"])
    }

    @Test(arguments: ["peer", "walk"])
    func failedPeerReadOrWalkRefusesEvenOwnerAndNeverRuns(fault: String) throws {
        let rig = try U6bRig(fault: fault)
        let (code, _, err) = try rig.home.cli(["ask", "a", "owner"])
        #expect(code == 3)
        #expect(err.trimmingCharacters(in: .whitespacesAndNewlines) == "agencil: refused: ancestry unknown")
        rig.base.refused(try rig.base.ask("a"), "refused: ancestry unknown", exit: 3)
        #expect(!FileManager.default.fileExists(atPath: rig.record + ".events"))
        #expect(try rig.sql("SELECT count(*) FROM runs;") == "0\n")
    }

    @Test func followupAndResultKeepChainedThreadsChain() throws {
        let rig = try U6bRig(["codex": "followup:b"])
        _ = try rig.root()
        let nested = try rig.data("codex")
        let thread = try #require(nested["thread"] as? String)
        #expect(try rig.read("codex.followup.exit") == "0")
        let followup = try rig.data("codex.followup")
        #expect(followup["thread"] as? String == thread)
        rig.chain(followup, ["a", "b"])
        rig.chain(try rig.base.cliData(["result", thread, "--wait", "10"]), ["a", "b"])
        rig.chain(try rig.base.cliData(["ask", "b", "followup", "--thread", thread, "--wait", "10"]), ["a", "b"])
    }
}
