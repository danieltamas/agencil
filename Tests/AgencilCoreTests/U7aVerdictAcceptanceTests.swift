import Foundation
import Testing

@Suite(.serialized) struct U7aVerdictAcceptanceTests {
    @Test func synthesizerFailureWinsOverAllApprovals() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["synthesizer": "d"]))
        try r.put("d.synthesis.fail")
        _ = try r.decided("INCOMPLETE", "synthesizer failed")
    }
    @Test func unparsableSynthesizerIsIncomplete() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["synthesizer": "d"]))
        try r.reply("d", "synthesis", "garbage"); try r.reply("d", "synthesis.retry", "garbage")
        _ = try r.decided("INCOMPLETE", "synthesizer failed")
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
        let r = try U7aRig(); try r.put("codex.signed-out")
        var seats = u7aSeats(); seats[1]["vendor"] = "shared"; seats[3]["vendor"] = "shared"
        try r.configure(u7aCouncil(["spare": ["d"], "quorum": 2]), seats: seats)
        try r.reply("c", u7aAnswer("abstain"))
        let v = try r.decided("PASS", brief: "change_kind: design\nquestion: inspect\n")
        #expect(try r.flags(v) == ["fallback_used", "vendor_missing", "single_vendor_quorum", "author_unknown"])
    }
    @Test func everySeatFailingIsDoneIncompleteNeverFailed() throws {
        let r = try U7aRig()
        for s in ["a", "b", "c"] { try r.put(s + ".blind.fail") }
        _ = try r.decided("INCOMPLETE", "quorum")
    }
}
