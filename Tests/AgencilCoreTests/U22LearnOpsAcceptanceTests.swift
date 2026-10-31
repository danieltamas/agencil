import Foundation
import Testing
import AgencilCore

// U22 acceptance 1-7. Seed through U12, then exercise the real socket and CLI.
@Suite(.serialized)
struct U22LearnOpsAcceptanceTests {
    @Test func proposalsExposeExactRowsFilterClosedAndUseNullForMissingFields() throws {
        let f = try U12Fixture()
        try f.seed(20)
        let drop = try f.drop()
        let applied = try #require(try f.propose(ideas: [
            .init(council: "review", variable: "tone", value: "brief")
        ]).first)
        try f.reviewed(applied)
        _ = try f.loop.approve(applied.id, at: u12Now)
        try f.reviewed(drop)
        let proposed = try #require(try f.propose(ideas: [
            .init(council: "review", variable: "tone", value: "detailed")
        ]).first)
        let rig = try U22Rig(f)
        let open = try rig.data("proposals", caller: "codex")
        let rows = try #require(open["proposals"] as? [[String: Any]])
        #expect(Set(rows.compactMap { $0["id"] as? String }) == [drop.id, proposed.id])
        let reviewedRow = try #require(rows.first { $0["id"] as? String == drop.id })
        let proposedRow = try #require(rows.first { $0["id"] as? String == proposed.id })
        let null = NSNull()
        try equal(reviewedRow, ["id": drop.id, "kind": "drop_seat", "council": "review",
            "seat": "maya", "replacement": null, "variable": null, "value": null,
            "status": "reviewed", "n": 20, "reviewer": "jonas", "verdict": "endorse",
            "note": "checked evidence"])
        try equal(proposedRow, ["id": proposed.id, "kind": "prompt_change", "council": "review",
            "seat": null, "replacement": null, "variable": "tone", "value": "detailed",
            "status": "proposed", "n": 20, "reviewer": null, "verdict": null, "note": null])
        let all = try #require(rig.data("proposals", extra: ["all": true])["proposals"] as? [[String: Any]])
        #expect(all.count == 3)
        #expect(all.first { $0["id"] as? String == applied.id }?["status"] as? String == "applied")
    }

    @Test func ownerRejectPersistsAndRepeatedRejectFails() throws {
        let f = try U12Fixture(); try f.seed(20)
        let p = try f.drop(), rig = try U22Rig(f)
        let before = try rig.bytes()
        try equal(rig.data("learn", extra: ["action": "reject", "id": p.id]),
                  ["action": "reject", "id": p.id])
        #expect(try rig.loop.proposals().first?.status == "rejected")
        try rig.failure(["action": "reject", "id": p.id], exit: 4)
        #expect(try rig.loop.proposals().first?.status == "rejected")
        #expect(try rig.bytes() == before)
        #expect(try rig.loop.versions().isEmpty)
    }

    @Test func unreviewedApprovalFailsWithoutChangingConfigOrVersions() throws {
        let f = try U12Fixture(); try f.seed(20)
        let p = try f.drop(), rig = try U22Rig(f)
        let before = try rig.bytes()
        #expect(try rig.data("proposals")["can_rollback"] as? Bool == false)
        try rig.failure(["action": "approve", "id": p.id], exit: 4)
        #expect(try rig.bytes() == before)
        #expect(try rig.loop.proposals().first?.status == "proposed")
        #expect(try rig.loop.versions().isEmpty)
    }

    @Test func reviewedApprovalChangesSeatsAndRollbackRestoresExactCouncils() throws {
        let f = try U12Fixture(); try f.seed(20)
        let p = try f.drop(); try f.reviewed(p)
        let original = try f.councilBody(), rig = try U22Rig(f)
        #expect(try rig.data("proposals")["can_rollback"] as? Bool == false)
        let result = try rig.data("learn", extra: ["action": "approve", "id": p.id])
        #expect(result["action"] as? String == "approve")
        #expect(result["id"] as? String == p.id)
        #expect(result["version"] as? Int == 2)
        #expect(try rig.seats() == ["jonas", "lee"])
        #expect(try rig.loop.proposals().first?.status == "applied")
        #expect(try rig.data("proposals")["can_rollback"] as? Bool == true)
        let rollback = try rig.data("learn", extra: ["action": "rollback"])
        #expect(rollback["action"] as? String == "rollback")
        #expect(rollback["id"] == nil)
        #expect(rollback["version"] as? Int == 3)
        #expect(try rig.seats() == ["maya", "jonas", "lee"])
        #expect(try ConfigStore(directory: rig.home.url).read().values["councils"] == original)
        #expect(try rig.loop.proposals().first?.status == "rolled_back")
    }

    @Test func ownerBoundaryAndInvalidActionsFailWithoutMutation() throws {
        let f = try U12Fixture(); try f.seed(20)
        let p = try f.drop(); try f.reviewed(p)
        let rig = try U22Rig(f), before = try rig.bytes()
        for action in ["approve", "reject", "rollback"] {
            var extra: [String: Any] = ["action": action]
            if action != "rollback" { extra["id"] = p.id }
            try rig.failure(extra, exit: 3, caller: "codex")
        }
        try rig.failure(["action": "bogus"], exit: 64)
        try rig.failure([:], exit: 64)
        for action in ["approve", "reject"] {
            try rig.failure(["action": action], exit: 64)
        }
        #expect(try rig.bytes() == before)
        #expect(try rig.loop.proposals().first?.status == "reviewed")
        #expect(try rig.loop.versions().isEmpty)
    }

    @Test func panelCountsBothOpenStatusesAndExcludesRejected() throws {
        let f = try U12Fixture(); try f.seed(20)
        let rejected = try f.drop(); try f.loop.reject(rejected.id, at: u12Now)
        _ = try f.drop()
        let reviewed = try #require(try f.propose(ideas: [
            .init(council: "review", variable: "tone", value: "brief")
        ]).first)
        try f.reviewed(reviewed)
        let rig = try U22Rig(f)
        #expect(try rig.data("panel")["proposals_pending"] as? Int == 2)
    }

    @Test func cliListsApprovesRejectsAndRollsBackThroughBroker() throws {
        let f = try U12Fixture(); try f.seed(20)
        let p = try f.drop(); try f.reviewed(p)
        let rig = try U22Rig(f)
        let listed = try rig.cli(["proposals"])
        #expect((listed["proposals"] as? [[String: Any]])?.first?["id"] as? String == p.id)
        let approved = try rig.cli(["learn", "approve", p.id])
        #expect(approved["action"] as? String == "approve")
        #expect(approved["id"] as? String == p.id)
        #expect(try rig.seats() == ["jonas", "lee"])
        #expect((try rig.cli(["proposals"])["proposals"] as? [[String: Any]])?.isEmpty == true)
        #expect((try rig.cli(["proposals", "--all"])["proposals"] as? [[String: Any]])?.count == 1)
        #expect(try rig.cli(["learn", "rollback"])["action"] as? String == "rollback")
        #expect(try rig.seats() == ["maya", "jonas", "lee"])
        let next = try #require(try rig.loop.propose(now: u12Now, candidates: [], ideas: []).first)
        #expect(try rig.cli(["learn", "reject", next.id])["id"] as? String == next.id)
        #expect(try rig.loop.proposals().last?.status == "rejected")
        let before = try rig.bytes(), versions = try rig.loop.versions()
        let (exit, _, _) = try rig.home.cli(["learn", "bogus"])
        #expect(exit == 64)
        #expect(try rig.bytes() == before)
        #expect(try rig.loop.versions() == versions)
    }

    @Test func invalidConfigRefusesProposalRead() throws {
        let f = try U12Fixture(); try f.seed(20); _ = try f.drop()
        let rig = try U22Rig(f)
        _ = try ConfigStore(directory: rig.home.url).update { $0["seats"] = "not-json" }
        let reply = try rig.home.request(["op": "proposals", "caller": "owner"])
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == 4)
        #expect(reply["data"] == nil)
    }

    private func equal(_ actual: Any, _ expected: Any) throws {
        #expect(try u6aText(actual) == u6aText(expected))
    }
}

private final class U22Rig {
    let home: BrokerHome
    let ledger: Ledger
    let loop: LearnLoop
    let broker: BrokerProcess

    init(_ fixture: U12Fixture) throws {
        let home = try BrokerHome()
        // VACUUM INTO captures committed WAL contents into a standalone real database.
        try fixture.sql("VACUUM INTO ?", [home.url.appendingPathComponent("agencil.sqlite").path])
        try fixture.bytes().write(to: home.url.appendingPathComponent("config.json"))
        self.home = home
        ledger = try Ledger(directory: home.url)
        loop = LearnLoop(ledger: ledger, directory: home.url)
        broker = try home.serve()
    }

    deinit { broker.kill() }

    func bytes() throws -> Data { try Data(contentsOf: home.url.appendingPathComponent("config.json")) }
    func seats() throws -> [String]? {
        try SeatConfig(values: ConfigStore(directory: home.url).read().values).council(named: "review")?.seats
    }
    func data(_ op: String, caller: String = "owner", extra: [String: Any] = [:]) throws -> [String: Any] {
        let reply = try home.request(["op": op, "caller": caller].merging(extra) { _, b in b })
        #expect(reply["ok"] as? Bool == true)
        return try #require(reply["data"] as? [String: Any])
    }
    func failure(_ extra: [String: Any], exit: Int, caller: String = "owner") throws {
        let reply = try home.request(["op": "learn", "caller": caller].merging(extra) { _, b in b })
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == exit)
        #expect(reply["data"] == nil)
        #expect(!(try #require(reply["error"] as? String)).isEmpty)
    }
    func cli(_ args: [String]) throws -> [String: Any] {
        let (exit, out, _) = try home.cli(args + ["--json"])
        #expect(exit == 0)
        let reply = try brokerJSON(Data(out.utf8))
        #expect(reply["ok"] as? Bool == true)
        return try #require(reply["data"] as? [String: Any])
    }
}
