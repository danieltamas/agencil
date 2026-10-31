import Foundation
import Testing

@Suite(.serialized) struct U7aRoundsAcceptanceTests {
    @Test func blindIsolationLedgerBarrierAndOtherClaimsOnlyInRebuttal() throws {
        let r = try U7aRig()
        try r.configure(u7aCouncil(["seats": ["a", "b"], "rounds": ["rebuttal": true]]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim(evidence: "ONLY_A_CLAIM")]))
        try r.reply("b", u7aAnswer(claims: [u7aClaim(evidence: "ONLY_B_CLAIM")]))
        _ = try r.decided("PASS")
        for (seat, other) in [("a", "b"), ("b", "a")] {
            let blind = try r.prompt(seat)
            #expect(!blind.contains("ONLY_" + other.uppercased() + "_CLAIM"))
            #expect(!blind.contains("CLAIM AG-"))
            let rebuttal = try r.prompt(seat, "rebuttal")
            let lines = rebuttal.components(separatedBy: "\n").filter { $0.hasPrefix("CLAIM AG-") }
            #expect(lines.count == 1)
            #expect(lines.first?.range(of: "^CLAIM AG-1-[12] \\[seat \(other)\\] p1 defect src/main.swift:1: ONLY_\(other.uppercased())_CLAIM$",
                                       options: .regularExpression) != nil)
            #expect(!rebuttal.contains("ONLY_" + seat.uppercased() + "_CLAIM"))
            #expect(!rebuttal.contains("PRIVATE_NOTES_MARKER"))
            // This read happens inside the stub before it answers rebuttal.
            let ledger = try r.text(#require(r.observations(seat, "rebuttal", suffix: "ledger").first))
            #expect(ledger.components(separatedBy: "\n").filter { $0.hasPrefix("AG-1-") }.count == 2)
        }
        let events = try r.text(r.control.appendingPathComponent("events")).split(separator: "\n")
        let ends = events.filter { $0.contains(" end ") && $0.hasSuffix(" blind") }
        let starts = events.filter { $0.contains(" start ") && $0.hasSuffix(" rebuttal") }
        #expect(ends.count == 2); #expect(starts.count == 2)
        #expect(ends.compactMap { Int($0.split(separator: " ")[0]) }.max()! <
                starts.compactMap { Int($0.split(separator: " ")[0]) }.min()!)
    }
    @Test func rebuttalOffUsesBlindVotesAndOnlyOneRound() throws {
        let r = try U7aRig(); try r.reply("a", u7aAnswer("block")); try r.reply("b", u7aAnswer("block"))
        _ = try r.decided("BLOCK", "no majority")
        #expect(r.observations(nil, "rebuttal").isEmpty)
        #expect(r.observations(nil, "blind").count == 3)
    }
    @Test func rebuttalVoteReplacesBlindVote() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rounds": ["rebuttal": true]]))
        for s in ["a", "b", "c"] { try r.reply(s, u7aAnswer("block")) }
        _ = try r.decided("PASS", "majority approve")
    }
    private func challenge(_ tie: Bool) throws {
        let r = try U7aRig()
        try r.configure(u7aCouncil(["rule": "any_blocker", "rounds": ["rebuttal": true, "challenge": true]]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim(), u7aClaim("p2", evidence: "P2_NOT_CHALLENGED")]))
        try r.reply("b", "rebuttal", u7aAnswer(assessments: [u7aAssessment("dispute")]))
        try r.reply("c", "rebuttal", u7aAnswer(assessments: [u7aAssessment("support")]))
        try r.reply("b", "challenge", u7aAnswer(assessments: [u7aAssessment("dispute")]))
        try r.reply("c", "challenge", u7aAnswer(assessments: [u7aAssessment(tie ? "abstain" : "dispute")]))
        let v = try r.decided(tie ? "BLOCK" : "PASS")
        #expect(r.observations("a", "challenge").isEmpty)
        for s in ["b", "c"] {
            let p = try r.prompt(s, "challenge")
            #expect(p.contains("CLAIM AG-1-1 [seat a] p1 defect"))
            #expect(p.contains("  SUPPORT c: EVIDENCE_support"))
            #expect(p.contains("  DISPUTE b: EVIDENCE_dispute"))
            #expect(!p.contains("P2_NOT_CHALLENGED"))
        }
        let c = try #require(r.rows(v, "claims").first { $0["id"] as? String == "AG-1-1" })
        #expect(c["refuted"] as? Bool == !tie)
    }
    @Test func twoDisputingVendorsRefuteOneBackingVendor() throws { try challenge(false) }
    @Test func vendorTieDoesNotRefuteBlocker() throws { try challenge(true) }
    @Test func repeatedDisputersFromOneVendorDoNotOutnumberAuthorVendor() throws {
        let r = try U7aRig(); var seats = u7aSeats(); seats[2]["vendor"] = "anthropic"
        try r.configure(u7aCouncil(["rule": "any_blocker", "rounds": ["rebuttal": true]]), seats: seats)
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        for s in ["b", "c"] { try r.reply(s, "rebuttal", u7aAnswer(assessments: [u7aAssessment("dispute")])) }
        _ = try r.decided("BLOCK")
    }
    @Test func fencedJSONAnswerIsAccepted() throws {
        let r = try U7aRig(); try r.reply("a", "```json\n" + u7aAnswer() + "\n```")
        let v = try r.decided("PASS"); #expect(try r.vote(v, "a")["valid"] as? Bool == true)
    }
    private func retries(_ malformed: String) throws {
        let r = try U7aRig(); try r.reply("a", malformed); try r.reply("a", "blind.retry", u7aAnswer())
        let v = try r.decided("PASS")
        #expect(try r.vote(v, "a")["valid"] as? Bool == true)
        let records = r.observations("a", "blind")
        #expect(records.count == 2)
        let p = try r.text(#require(records.last))
        #expect(p.contains("\nRETRY: 1")); #expect(p.contains("\nERROR: "))
        #expect(p.hasPrefix(try r.text(#require(records.first))))
    }
    @Test func missingVoteRetriesOnceThenCountsSuccess() throws { try retries("{\"claims\":[]}") }
    @Test func invalidVoteRetriesOnce() throws { try retries("{\"vote\":\"yes\",\"claims\":[]}") }
    @Test func invalidSeverityRetriesOnce() throws { try retries(u7aAnswer(claims: [u7aClaim("critical")])) }
    @Test func invalidConfidenceRetriesOnce() throws {
        var c = u7aClaim(); c["confidence"] = 1.01; try retries(u7aAnswer(claims: [c]))
    }
    @Test func claimWithoutIDRetriesOnce() throws {
        var c = u7aClaim(); c.removeValue(forKey: "id"); try retries(u7aAnswer(claims: [c]))
    }
    @Test func zeroLineRetriesOnce() throws {
        var c = u7aClaim(); c["line"] = 0; try retries(u7aAnswer(claims: [c]))
    }
    @Test func nonObjectAnswerRetriesOnce() throws { try retries("[]") }
    @Test func twiceUnparsableSeatIsFailedAndExcluded() throws {
        let r = try U7aRig(); try r.reply("a", "garbage"); try r.reply("a", "blind.retry", "garbage")
        let v = try r.decided("PASS")
        let a = try r.vote(v, "a")
        #expect(a["state"] as? String == "failed"); #expect(a["reason"] as? String == "failed: unparsable")
        #expect(a["valid"] as? Bool == false); #expect(try r.rows(v, "claims").isEmpty)
        #expect(r.observations("a", "blind").count == 2)
    }
    @Test func laterUnparsableRoundExcludesEarlierClaims() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rounds": ["rebuttal": true], "rule": "any_blocker"]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        try r.reply("a", "rebuttal", "garbage"); try r.reply("a", "rebuttal.retry", "garbage")
        let v = try r.decided("PASS"); #expect(try r.rows(v, "claims").isEmpty)
        #expect(try r.vote(v, "a")["valid"] as? Bool == false)
    }
    @Test func unknownAndOwnAssessmentsAreDropped() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rounds": ["rebuttal": true]]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        try r.reply("a", "rebuttal", u7aAnswer(assessments: [u7aAssessment("dispute"), u7aAssessment("support", "AG-999-1")]))
        let v = try r.decided("PASS"); let c = try #require(r.rows(v, "claims").first)
        #expect(c["backers"] as? [String] == ["a"]); #expect(c["dissenters"] as? [String] == [])
        #expect(try r.sql("SELECT count(*) FROM assessments;") == "0\n")
    }
    @Test func evidenceIsCutAt4096UTF8Bytes() throws {
        let r = try U7aRig(); try r.reply("a", u7aAnswer(claims: [u7aClaim(evidence: String(repeating: "x", count: 5000))]))
        let v = try r.decided("PASS"); let c = try #require(r.rows(v, "claims").first)
        #expect((c["evidence"] as? String)?.utf8.count == 4096)
    }
    @Test func singleBackerDisputedByTwoAppearsInMinorityWithSeatAndVendor() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rounds": ["rebuttal": true]]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        for s in ["b", "c"] { try r.reply(s, "rebuttal", u7aAnswer(assessments: [u7aAssessment("dispute")])) }
        let v = try r.decided("PASS"); let m = try r.rows(v, "minority")
        #expect(m.count == 1); #expect(m.first?["claim"] as? String == "AG-1-1")
        #expect(m.first?["seat"] as? String == "a"); #expect(m.first?["vendor"] as? String == "openai")
    }
    @Test func majorityBackedClaimIsAbsentFromMinority() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["rounds": ["rebuttal": true]]))
        try r.reply("a", u7aAnswer(claims: [u7aClaim()]))
        try r.reply("b", "rebuttal", u7aAnswer(assessments: [u7aAssessment("support")]))
        let v = try r.decided("PASS"); #expect(try r.rows(v, "minority").isEmpty)
    }
}
