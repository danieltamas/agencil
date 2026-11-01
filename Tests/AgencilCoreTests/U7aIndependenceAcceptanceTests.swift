import Foundation
import Testing

@Suite(.serialized) struct U7aIndependenceAcceptanceTests {
    @Test func silentSeatIsSwappedAndItsProcessGroupDies() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["silent_after": 0.05, "spare": ["d"]]))
        try r.put("a.blind.silent")
        let v = try r.decided("PASS")
        #expect(try r.flags(v).contains("fallback_used"))
        #expect(try r.vote(v, "d")["valid"] as? Bool == true)
        try r.stoppedPIDs("a")
    }
    @Test func silentSeatWithoutSpareAbstains() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["silent_after": 0.05]))
        try r.put("a.blind.silent")
        let v = try r.decided("PASS"); let a = try r.vote(v, "a")
        #expect(a["state"] as? String == "abstained"); #expect(a["reason"] as? String == "silent")
        #expect(a["valid"] as? Bool == false); try r.stoppedPIDs("a")
    }
    @Test func silenceLosingQuorumIsIncomplete() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["silent_after": 0.05]))
        try r.put("a.blind.silent"); try r.put("b.blind.silent")
        _ = try r.decided("INCOMPLETE", "quorum")
        try r.stoppedPIDs("a"); try r.stoppedPIDs("b")
    }
    @Test func signedOutSeatIsReplacedBySpare() throws {
        let r = try U7aRig(); try r.put("codex.signed-out")
        var seats = u7aSeats(); seats[3]["vendor"] = "deepseek"
        try r.configure(u7aCouncil(["spare": ["d"]]), seats: seats)
        let v = try r.decided("PASS")
        #expect(try r.flags(v).contains("fallback_used")); #expect(r.observations("a").isEmpty)
        #expect(r.observations("d", "blind").count == 1)
        #expect(try r.rows(v, "votes").compactMap { $0["seat"] as? String } == ["d", "b", "c"])
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='a';") == "not_logged_in\n")
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE seat='a';") == "0\n")
        #expect(try r.vote(v, "d")["valid"] as? Bool == true)
    }
    @Test func localResidencyRefusalUsesLocalSpare() throws {
        let r = try U7aRig(); var seats = u7aSeats()
        for i in [1, 2, 3] { seats[i]["hosted"] = false }
        try r.configure(u7aCouncil(["residency": "local", "spare": ["d"]]), seats: seats)
        let v = try r.decided("PASS")
        #expect(try r.flags(v).contains("fallback_used")); #expect(r.observations("a").isEmpty)
        #expect(!r.observations("d").isEmpty)
    }
    @Test func policyRefusalUsesCapableSpare() throws {
        let r = try U7aRig()
        try r.configure(u7aCouncil(["seats": ["a", "c"], "spare": ["b"]]),
            routes: [u6aRoute("panel").merging(["requires": ["no_further_mcp"]]) { _, b in b }])
        let v = try r.decided("PASS")
        #expect(r.observations("c").isEmpty); #expect(!r.observations("b").isEmpty)
        #expect(try r.flags(v).contains("fallback_used"))
    }
    @Test func unusableSeatWithoutSpareFailsAndDoesNotVote() throws {
        let r = try U7aRig(); try r.put("codex.signed-out")
        try r.wakeRefused("failed: preflight: a not_logged_in")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='a';") == "not_logged_in\n")
        #expect(r.observations("a").isEmpty)
    }
    @Test func seatFailingAfterHealthyProbeDoesNotVote() throws {
        let r = try U7aRig(); try r.put("a.blind.fail")
        let v = try r.decided("PASS"); let a = try r.vote(v, "a")
        #expect(a["state"] as? String == "failed"); #expect(a["valid"] as? Bool == false)
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='a';") == "ok\n")
        #expect(r.observations("a", "blind").count == 1)
        #expect(try r.sql("SELECT exit_code FROM seat_runs WHERE seat='a';") == "1\n")
    }
    @Test func recusedSeatIsNeverSpawnedOrUsedAsSpare() throws {
        let r = try U7aRig()
        try r.configure(u7aCouncil(["seats": ["a", "b", "c"], "spare": ["d"]]),
            seats: u7aSeats().map { $0["name"] as? String == "d" ? $0.merging(["vendor": "openai"]) { _, b in b } : $0 })
        try r.put("b.blind.fail")
        let v = try r.decided("INCOMPLETE", "quorum", extra: ["--author-vendor", "openai"])
        #expect(r.observations("a").isEmpty); #expect(r.observations("d").isEmpty)
        #expect(r.observations("a", suffix: "argv").isEmpty)
        #expect(r.observations("d", suffix: "argv").isEmpty)
        #expect(try r.vote(v, "a")["state"] as? String == "recused")
    }
    @Test func onlyConfiguredSynthesizerOfAuthorsVendorRefusesTheWakeBeforeAnyWork() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["seats": ["b", "c"], "synthesizer": "a"]))
        try r.put("refused.brief", "change_kind: design\nquestion: inspect\n")
        let (code, out, error) = try r.home.cli(["wake", "panel", "--brief",
            r.control.appendingPathComponent("refused.brief").path, "--wait", "15",
            "--author-vendor", "openai", "--json"])
        #expect(code == 4)
        #expect(out.isEmpty)
        #expect(error.hasPrefix("agencil: failed: preflight: every synthesizer is of the author's vendor"))
        #expect(try r.sql("SELECT outcome FROM requests;") == "failed\n")
        for table in ["briefs", "snapshots", "runs", "sittings", "seat_runs", "preflights"] {
            #expect(try r.sql("SELECT count(*) FROM \(table);") == "0\n")
        }
        #expect(r.observations().isEmpty)
    }
    @Test func secondSynthesizerFromAnotherVendorRuns() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["seats": ["b", "c"], "synthesizer": ["a", "d"]]))
        let v = try r.decided("PASS", extra: ["--author-vendor", "openai"])
        #expect(r.observations("a").isEmpty); #expect(r.observations("d", "synthesis").count == 1)
        #expect(v["summary"] as? String == "SUMMARY_MARKER")
        #expect(r.observations("codex", "ask").isEmpty)
        #expect(r.observations("opencode", "ask").count == 1)
        #expect(try r.sql("SELECT seat,reason FROM preflights ORDER BY seat;") == "b|ok\nc|ok\nd|ok\n")
    }
    @Test func noConfiguredSynthesizerSkipsSynthesisAndFirstVerdictRow() throws {
        let r = try U7aRig(); _ = try r.decided("PASS")
        #expect(r.observations(nil, "synthesis").isEmpty)
    }
    private func unknown(_ vendor: String?, highRisk: Bool) throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["high_risk": highRisk]))
        let brief = "change_kind: design\nquestion: inspect\n" + (vendor.map { "author_vendor: \($0)\n" } ?? "")
        let v = try r.decided(highRisk ? "INCOMPLETE" : "PASS", brief: brief)
        #expect(try r.flags(v) == ["author_unknown"]); #expect(v["author_vendor"] as? String == "unknown")
    }
    @Test func ownerWithoutAuthorIsFlaggedOnOrdinaryCouncil() throws { try unknown(nil, highRisk: false) }
    @Test func ownerWithoutAuthorIsIncompleteOnHighRiskCouncil() throws { try unknown(nil, highRisk: true) }
    @Test func unrecognizedAuthorIsFlaggedOnOrdinaryCouncil() throws { try unknown("acme-ai", highRisk: false) }
    @Test func unrecognizedAuthorIsIncompleteOnHighRiskCouncil() throws { try unknown("acme-ai", highRisk: true) }
    @Test func authorVendorFlagOverridesBrief() throws {
        let r = try U7aRig()
        let v = try r.decided("PASS", extra: ["--author-vendor", "openai"])
        #expect(v["author_vendor"] as? String == "openai"); #expect(r.observations("a").isEmpty)
    }
    @Test func seatChildWakeInheritsHarnessVendorThroughCapability() throws {
        let r = try U7aRig()
        try r.configure(routes: [u6aRoute("a"), u6aRoute("panel", callers: ["owner", "a"])])
        try r.put("codex.ask", "parent finished")
        try r.put("codex.ask.child")
        try r.put("child.brief", "change_kind: design\nquestion: child inspect\n")
        _ = try r.cli(["ask", "a", "parent", "--wait", "15"], exit: 0)
        let url = try #require(r.observations("codex", "ask", suffix: "child").first)
        let envelope = try brokerJSON(Data(r.text(url).utf8))
        let v = try r.verdict(#require(envelope["data"] as? [String: Any]))
        #expect(v["author_vendor"] as? String == "openai")
        #expect(!r.observations("b", "blind").isEmpty)
        #expect(r.observations("a", "blind").isEmpty)
    }
    @Test func sittingSeatsRespectSeatsAtOnceCapacity() throws {
        let r = try U7aRig()
        try r.configure(raw: ["limits": u6aText(["seats_at_once": 1])])
        for s in ["a", "b", "c"] { try r.put(s + ".blind.delay", "0.15") }
        for kind in ["codex", "claude", "hermes"] { try r.put(kind + ".ask.delay", "0.15") }
        _ = try r.decided("PASS")
        let events = try r.text(r.control.appendingPathComponent("events")).split(separator: "\n")
        #expect(events.filter { $0.contains(" start ") }.count == 6)
        #expect(events.filter { $0.contains(" start ") && $0.hasSuffix(" ask") }.count == 3)
        #expect(r.observations(nil, "blind").count == 3)
        var active = 0, maximum = 0
        for e in events {
            active += e.contains(" start ") ? 1 : -1
            maximum = max(maximum, active)
            #expect(active >= 0)
        }
        #expect(maximum == 1); #expect(active == 0)
    }
    @Test func hardBudgetOnCouncilNameRefusesUnboundedSeatBeforeSpawn() throws {
        let r = try U7aRig()
        // Harness seats lack provider token accounting, so a hard token budget refuses them.
        try r.configure(raw: ["budgets": u6aText([u6cBudget(key: "panel", tokens: 100)])])
        try r.wakeRefused("failed: preflight: a refused: budget")
        #expect(r.observations().isEmpty)
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "0\n")
        #expect(try r.sql("SELECT count(*) FROM launches;") == "0\n")
    }
}
