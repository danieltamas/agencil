import Foundation
import Testing

@Suite(.serialized) struct U7aLifecycleAcceptanceTests {
    @Test func verdictHasExactKeysAndTypesAndJSONEnvelope() throws {
        let r = try U7aRig(); try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        let v = try r.decided("PASS")
        #expect(Set(v.keys) == Set(["sitting", "council", "state", "verdict", "reasons", "rule", "high_risk",
            "snapshot", "author_vendor", "votes", "claims", "minority", "independence"]))
        for key in ["sitting", "council", "state", "verdict", "rule", "snapshot", "author_vendor"] {
            #expect(v[key] is String)
        }
        #expect(v["high_risk"] is Bool); #expect(v["reasons"] is [String]); #expect(v["independence"] is [String])
        #expect((v["sitting"] as? String)?.range(of: "^sit_[0-9a-f]+$", options: .regularExpression) != nil)
        for vote in try r.rows(v, "votes") {
            #expect(Set(vote.keys) == Set(["seat", "vendor", "state", "vote", "valid"]))
            #expect(vote["seat"] is String); #expect(vote["vendor"] is String)
            #expect(vote["state"] as? String == "answered"); #expect(vote["vote"] is String); #expect(vote["valid"] is Bool)
        }
        let claim = try #require(r.rows(v, "claims").first)
        #expect(Set(claim.keys) == Set(["id", "seat", "vendor", "kind", "severity", "confidence", "file", "line",
                                       "evidence", "backers", "dissenters", "refuted", "minority"]))
        for key in ["id", "seat", "vendor", "kind", "severity", "file", "evidence"] { #expect(claim[key] is String) }
        #expect(claim["confidence"] is NSNumber); #expect(claim["line"] as? Int == 1)
        #expect(claim["backers"] is [String]); #expect(claim["dissenters"] is [String])
        #expect(claim["refuted"] is Bool); #expect(claim["minority"] is Bool)
        for row in try r.rows(v, "minority") {
            #expect(Set(row.keys) == Set(["claim", "seat", "vendor"]))
            #expect(row.values.allSatisfy { $0 is String })
        }
    }
    private func resultExit(_ expected: String, _ code: Int32) throws {
        let r = try U7aRig()
        if expected == "BLOCK" {
            try r.reply("a", u7aAnswer("block")); try r.reply("b", u7aAnswer("block"))
        } else if expected == "INCOMPLETE" {
            try r.reply("a", u7aAnswer("abstain")); try r.reply("b", u7aAnswer("abstain"))
        }
        let v = try r.decided(expected); let id = try #require(v["sitting"] as? String)
        let result = try r.verdict(r.cli(["result", id, "--wait", "15"], exit: code))
        #expect(result["verdict"] as? String == expected)
    }
    @Test func resultPassExitsZero() throws { try resultExit("PASS", 0) }
    @Test func resultBlockExitsOne() throws { try resultExit("BLOCK", 1) }
    @Test func resultIncompleteExitsTwo() throws { try resultExit("INCOMPLETE", 2) }
    private func pending(_ r: U7aRig) throws -> String {
        for s in ["a", "b", "c"] { try r.put(s + ".blind.hold") }
        try r.put("pending.brief", "change_kind: design\nquestion: inspect\nauthor_vendor: google\n")
        let p = try r.cli(["wake", "panel", "--brief", r.control.appendingPathComponent("pending.brief").path,
                          "--wait", "0"], exit: 2)
        #expect(p["state"] as? String == "pending")
        return try #require(p["sitting"] as? String)
    }
    @Test func shortWaitIsPendingStatusDescribesSeatsThenResultWaitCompletes() throws {
        let r = try U7aRig(); let id = try pending(r)
        try brokerPoll(15) { r.observations().count == 3 }
        let s = try r.cli(["status", id], exit: 0)
        #expect(Set(s.keys) == Set(["sitting", "council", "state", "round", "seats"]))
        #expect(s["sitting"] as? String == id); #expect(s["council"] as? String == "panel")
        #expect(s["round"] as? String == "blind")
        for row in try r.rows(s, "seats") {
            for k in ["seat", "vendor", "state", "round"] { #expect(row[k] is String) }
        }
        try r.put("release")
        let v = try r.verdict(r.cli(["result", id, "--wait", "15"], exit: 0))
        #expect(v["verdict"] as? String == "PASS")
    }
    @Test func stopKillsEverySeatProcessGroupAndMarksSittingStopped() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["silent_after": 0.95]))
        for s in ["a", "b", "c"] { try r.put(s + ".blind.silent") }
        let id = try pending(r)
        try brokerPoll(15) { r.observations().count == 3 }
        try r.put("release")
        try brokerPoll(15) { r.observations(suffix: "child-pid").count == 3 }
        _ = try r.cli(["stop", id], exit: 0)
        let v = try r.cli(["result", id, "--wait", "15"], exit: 4)
        #expect(v["state"] as? String == "failed"); #expect(v["reason"] as? String == "stopped")
        for s in ["a", "b", "c"] { try r.stoppedPIDs(s) }
    }
    @Test func ledgerRecordsSnapshotBriefClaimsAssessmentsVerdictAndEverySeatRound() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rounds": ["rebuttal": true]]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        try r.reply("b", "rebuttal", u7aAnswer(assessments: [u7aAssessment("support")]))
        let v = try r.decided("PASS")
        let id = try #require(v["sitting"] as? String), snapshot = try #require(v["snapshot"] as? String)
        #expect(try r.sql("SELECT count(*) FROM runs WHERE id='\(id)' AND kind='sitting' AND snapshot_id='\(snapshot)';") == "1\n")
        #expect(try r.sql("SELECT count(*) FROM snapshots;") == "1\n")
        #expect(try r.sql("SELECT author_vendor FROM briefs;") == "google\n")
        #expect(try r.sql("SELECT body FROM briefs;").contains("inspect packet"))
        #expect(try r.sql("SELECT id FROM claims WHERE run_id='\(id)' AND seat_run_id IS NOT NULL;") == "AG-1-1\n")
        #expect(try r.sql("SELECT count(*) FROM assessments WHERE run_id='\(id)' AND snapshot_id='\(snapshot)';") == "1\n")
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE run_id='\(id)';") == "6\n")
        #expect(try r.sql("SELECT verdict FROM verdicts WHERE run_id='\(id)' AND snapshot_id='\(snapshot)';") == "PASS\n")
        // SQLite validates stored JSON rather than relying on string formatting.
        #expect(try r.sql("SELECT json_valid(independence_flags),json_valid(minority) FROM verdicts WHERE run_id='\(id)';") == "1|1\n")
        _ = try r.decided("PASS")
        #expect(try r.sql("SELECT count(*) FROM claims WHERE id='AG-2-1';") == "1\n")
        #expect(try r.sql("SELECT count(*) FROM verdicts;") == "2\n")
    }
}
