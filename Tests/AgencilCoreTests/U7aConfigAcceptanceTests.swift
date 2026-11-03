import Foundation
import Testing

@Suite(.serialized) struct U7aConfigAcceptanceTests {
    private func invalid(_ councils: Any, seats: [[String: Any]] = u7aSeats(), key: String = "councils") throws {
        let r = try U7aRig()
        try r.configure(seats: seats, councils: councils)
        for request: [String: Any] in [
            ["op": "ask", "caller": "owner", "target": "a", "question": "probe"],
            ["op": "wake", "caller": "owner", "council": "panel", "change_kind": "design", "question": "probe"]
        ] {
            let reply = try r.home.request(request)
            #expect(reply["ok"] as? Bool == false)
            #expect(reply["exit"] as? Int == 4)
            #expect((reply["error"] as? String)?.hasPrefix("failed: config \(key) is invalid: ") == true)
        }
        try r.noRuns()
    }
    private func field(_ key: String, _ value: Any) throws { try invalid([u7aCouncil([key: value])]) }
    @Test func councilsMustBeAList() throws { try invalid(["name": "panel"]) }
    @Test func councilNameMustBeValid() throws { try field("name", "Bad Name") }
    @Test func duplicateCouncilIsRejected() throws { try invalid([u7aCouncil(), u7aCouncil()]) }
    @Test func councilCannotHaveSeatName() throws { try field("name", "a") }
    @Test func unknownSeatIsRejected() throws { try field("seats", ["absent"]) }
    @Test func emptySeatsAreRejected() throws { try field("seats", [String]()) }
    @Test func duplicateSeatIsRejected() throws { try field("seats", ["a", "a"]) }
    @Test func overlappingSpareIsRejected() throws { try field("spare", ["a"]) }
    @Test func duplicateSpareIsRejected() throws { try field("spare", ["d", "d"]) }
    @Test func unknownSynthesizerIsRejected() throws { try field("synthesizer", "absent") }
    @Test func synthesizerCannotBeVotingSeat() throws { try field("synthesizer", "a") }
    @Test func badRuleIsRejected() throws { try field("rule", "plurality") }
    @Test func zeroQuorumIsRejected() throws { try field("quorum", 0) }
    @Test func excessiveQuorumIsRejected() throws { try field("quorum", 4) }
    @Test func highRiskMustBeBoolean() throws { try field("high_risk", "true") }
    @Test func roundsMustBeAnObject() throws { try field("rounds", true) }
    @Test func badResidencyIsRejected() throws { try field("residency", "remote") }
    @Test func silentAfterBelowRangeIsRejected() throws { try field("silent_after", 0.04) }
    @Test func silentAfterAboveRangeIsRejected() throws { try field("silent_after", 0.96) }
    @Test func deadlineBelowRangeIsRejected() throws { try field("deadline_seconds", 9) }
    @Test func deadlineAboveRangeIsRejected() throws { try field("deadline_seconds", 7201) }
    @Test func badSeatVendorIsRejectedByEveryOperation() throws {
        var seats = u7aSeats(); seats[0]["vendor"] = "Bad Vendor"
        try invalid([u7aCouncil()], seats: seats, key: "seats")
    }
    @Test func validSingleSeatCouncilIsAccepted() throws {
        let r = try U7aRig(); try r.configure(u7aCouncil(["seats": ["a"]]))
        let v = try r.decided("PASS")
        #expect(try r.rows(v, "votes").count == 1)
    }
    @Test func missingRouteWritesRefusalWithoutRun() throws {
        let r = try U7aRig(); try r.configure(routes: [u6aRoute("a")])
        let reply = try r.home.request(["op": "wake", "caller": "claude", "council": "panel",
                                       "change_kind": "design", "question": "probe"])
        r.base.refused(reply, "refused: no route from claude to panel", exit: 3)
        try r.noRuns()
        #expect(try r.sql("SELECT count(*) FROM requests WHERE outcome='refused';") == "1\n")
    }
    @Test func unknownCouncilWritesRefusalWithoutRun() throws {
        let r = try U7aRig(); try r.configure(routes: [u6aRoute("absent")])
        r.base.refused(try r.home.request(["op": "wake", "caller": "owner", "council": "absent",
            "change_kind": "design", "question": "probe"]), "failed: no council named absent")
        try r.noRuns()
        #expect(try r.sql(".dump requests").contains("refused"))
    }
    @Test func nonGitRepositoryWritesRefusalWithoutRun() throws {
        let r = try U7aRig()
        r.base.refused(try r.home.request(["op": "wake", "caller": "owner", "council": "panel",
            "change_kind": "design", "question": "probe", "repo": r.control.path]),
            "failed: repo \(r.control.path) is not a git repository")
        try r.noRuns(); #expect(try r.sql(".dump requests").contains("refused"))
    }
    private func usage(_ brief: String) throws {
        let r = try U7aRig(); try r.put("bad.brief", brief)
        let (code, _, _) = try r.home.cli(["wake", "panel", "--brief", r.control.appendingPathComponent("bad.brief").path])
        #expect(code == 64); try r.noRuns()
    }
    @Test func missingChangeKindIsUsageError() throws { try usage("question: inspect\n") }
    @Test func missingQuestionIsUsageError() throws { try usage("change_kind: design\n") }
    @Test func codeBriefWithoutDiffIsUsageError() throws { try usage("change_kind: code\nquestion: inspect\n") }
    @Test func councilNeverUsesRouteFallbacks() throws {
        let r = try U7aRig(); try r.put("codex.signed-out")
        try r.configure(u7aCouncil(["seats": ["a"]]), routes: [u6aRoute("panel", fallbacks: ["b"])])
        try r.wakeRefused("failed: preflight: a not_logged_in")
        #expect(r.observations("b").isEmpty)
        #expect(try r.sql("SELECT seat,reason FROM preflights;") == "a|not_logged_in\n")
    }
}

extension U7aRig {
    // Probe processes are availability checks, never council participation.
    func seatStarts() throws -> [URL] {
        try observations().filter { try text($0) != "Reply with exactly: OK" }
    }

    func wakeRefused(_ message: String) throws {
        try put("refused.brief", "change_kind: design\nquestion: inspect\nauthor_vendor: google\n")
        let (code, out, error) = try home.cli(["wake", "panel", "--brief",
            control.appendingPathComponent("refused.brief").path, "--wait", "15", "--json"])
        #expect(code == 4)
        #expect(out.isEmpty)
        #expect(error.hasPrefix("agencil: " + message))
        #expect(try sql("SELECT outcome FROM requests;") == "failed\n")
        for table in ["briefs", "snapshots", "runs", "sittings", "seat_runs"] {
            #expect(try sql("SELECT count(*) FROM \(table);") == "0\n")
        }
        #expect(try seatStarts().isEmpty)
    }
}
