import Foundation
import Testing

@Suite(.serialized) struct U7aVerdictAcceptanceTests {
    @Test func synthesizerFailureWinsOverAllApprovals() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["synthesizer": "d"]))
        try r.put("d.synthesis.fail")
        let v = try r.decided("INCOMPLETE", "synthesizer failed")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='d';") == "ok\n")
        #expect(r.observations("d", "synthesis").count == 1)
        for row in try r.rows(v, "votes") {
            #expect(row["valid"] as? Bool == true); #expect(row["vote"] as? String == "approve")
        }
    }
    @Test func unparsableSynthesizerIsIncomplete() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["synthesizer": "d"]))
        try r.reply("d", "synthesis", "garbage"); try r.reply("d", "synthesis.retry", "garbage")
        _ = try r.decided("INCOMPLETE", "synthesizer failed")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='d';") == "ok\n")
        #expect(r.observations("d", "synthesis").count == 2)
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE seat='d' AND exit_code=0;") == "0\n")
    }
    @Test func synthesizerFailingProbeRefusesBeforeApprovals() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["synthesizer": "d"]))
        try r.put("opencode.ask.fail")
        try r.wakeRefused("failed: preflight: d error")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='d';") == "error\n")
        #expect(r.observations("d", "synthesis").isEmpty)
    }
    @Test func quorumLossWinsOverHighRiskIndependence() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["high_risk": true]))
        for seat in ["a", "b"] { try r.reply(seat, u7aAnswer("abstain")) }
        _ = try r.decided("INCOMPLETE", "quorum")
    }
    @Test func highRiskFlagWinsOverAnyBlocker() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["high_risk": true, "rule": "any_blocker"]))
        try r.reply("a", u7aAnswer("block", claims: [u7aClaim()]))
        _ = try r.decided("INCOMPLETE", "independence:",
            brief: "change_kind: design\nquestion: inspect\n")
    }
    @Test func anyBlockerWithoutQualifyingClaimPasses() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rule": "any_blocker"]))
        try r.reply("a", u7aAnswer("block")); _ = try r.decided("PASS", "no blocker")
    }
    @Test func anyBlockerWithUnrefutedP1Blocks() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rule": "any_blocker"]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        _ = try r.decided("BLOCK", "blocker AG-")
    }
    @Test func anyBlockerWithP2AlonePasses() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rule": "any_blocker"]))
        try r.reply("a", u7aAnswer("block", claims: [u7aClaim("p2")]))
        _ = try r.decided("PASS", "no blocker")
    }
    @Test func unanimousAllApprovePasses() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rule": "unanimous"]))
        _ = try r.decided("PASS", "unanimous approve")
    }
    @Test func unanimousOneBlockBlocks() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rule": "unanimous"]))
        try r.reply("c", u7aAnswer("block")); _ = try r.decided("BLOCK", "not unanimous")
    }
    @Test func unanimousIgnoresAbstention() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rule": "unanimous"]))
        try r.reply("c", u7aAnswer("abstain")); _ = try r.decided("PASS", "unanimous approve")
    }
    @Test func majorityMoreThanHalfPasses() throws {
        let r = try U7aRig(); try r.reply("c", u7aAnswer("block"))
        _ = try r.decided("PASS", "majority approve")
    }
    @Test func majorityExactlyHalfBlocks() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["seats": ["a", "b"]]))
        try r.reply("b", u7aAnswer("block")); _ = try r.decided("BLOCK", "no majority")
    }
    @Test func defaultQuorumRejectsThreeVotesFromOneVendor() throws {
        let r = try U7aRig()
        let seats = u7aSeats().map { $0.merging(["vendor": "shared"]) { _, b in b } }
        try r.configure(seats: seats); _ = try r.decided("INCOMPLETE", "quorum")
    }
    @Test func explicitQuorumAllowsOneVendorAndFlagsIt() throws {
        let r = try U7aRig()
        let seats = u7aSeats().map { $0.merging(["vendor": "shared"]) { _, b in b } }
        try r.configure(u7aCouncil(["quorum": 2]), seats: seats)
        #expect(try r.flags(r.decided("PASS")) == ["single_vendor_quorum"])
    }
    @Test func missingVendorIsFlaggedWithValidDefaultQuorum() throws {
        let r = try U7aRig(); try r.reply("c", u7aAnswer("abstain"))
        #expect(try r.flags(r.decided("PASS")) == ["vendor_missing"])
    }
    @Test func independenceFlagsHaveContractOrder() throws {
        let r = try U7aRig(); try r.put("a.blind.silent")
        var seats = u7aSeats(); seats[1]["vendor"] = "shared"; seats[3]["vendor"] = "shared"
        // U25 rejects duplicate-vendor spares at the gate. This fallback happens
        // after healthy probes, retaining the in-sitting flag ordering contract.
        try r.configure(u7aCouncil(["spare": ["d"], "quorum": 2, "silent_after": 0.05]), seats: seats)
        try r.reply("c", u7aAnswer("abstain"))
        let v = try r.decided("PASS", brief: "change_kind: design\nquestion: inspect\n")
        #expect(try r.flags(v) == ["fallback_used", "vendor_missing", "single_vendor_quorum", "author_unknown"])
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='a';") == "ok\n")
        #expect(try r.vote(v, "d")["valid"] as? Bool == true)
        try r.stoppedPIDs("a")
    }
    @Test func duplicateVendorSpareCannotSupplyFlagsByPassingWakeGate() throws {
        let r = try U7aRig(); try r.put("codex.signed-out")
        var seats = u7aSeats(); seats[1]["vendor"] = "shared"; seats[3]["vendor"] = "shared"
        try r.configure(u7aCouncil(["spare": ["d"], "quorum": 2]), seats: seats)
        _ = try r.base.data(r.home.request(["op": "preflight", "caller": "owner", "seats": ["d"], "probe": true]))
        try r.wakeRefused("failed: preflight: a not_logged_in")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='d';") == "ok\n")
    }
    @Test func everySeatFailingIsDoneIncompleteNeverFailed() throws {
        let r = try U7aRig()
        for s in ["a", "b", "c"] { try r.put(s + ".blind.fail") }
        _ = try r.decided("INCOMPLETE", "quorum")
    }
}
