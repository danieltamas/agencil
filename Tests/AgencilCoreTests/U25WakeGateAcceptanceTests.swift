import Foundation
import Testing
import AgencilCore

@Suite(.serialized)
struct U25WakeGateAcceptanceTests {
    // Acceptance 8: an already seated vendor cannot replace an unavailable seat.
    @Test func duplicateVendorSpareRefusesBeforeAnyWorkIsRecorded() throws {
        let r = try U25Rig()
        var seats = u25Seats(); seats[3]["vendor"] = "lumen"
        try r.configure(seats: seats, council: u7aCouncil(["spare": ["d"]]))
        try r.mode("codex", "usage-limit")
        _ = try r.preflight(probe: true)
        let before = r.invocations()
        try r.failure(r.wake(), exit: 4, contains: ["failed: preflight:", "a usage_limit", "Oct 9"])
        #expect(r.invocations() == before)
        #expect(try r.sql("SELECT outcome FROM requests;") == "failed\n")
        try r.noWork()
    }

    // Acceptance 9: the first healthy spare of a new vendor fills the failed slot.
    @Test func healthySpareSitsAndVerdictRecordsFallback() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["spare": ["d"]]))
        try r.mode("codex", "model-gone")
        let v = try r.passed()
        let votes = try #require(v["votes"] as? [[String: Any]])
        #expect(Set(votes.compactMap { $0["seat"] as? String }) == ["b", "c", "d"])
        #expect((v["independence"] as? [String])?.contains("fallback_used") == true)
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE seat='a';") == "0\n")
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE seat='d' AND exit_code=0;") == "1\n")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='a';") == "model_unavailable\n")
    }

    // Acceptance 10: a healthy U7a council keeps its normal rounds and verdict.
    @Test func healthyPanelProbesOnceAndReusesStandingsAcrossRounds() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["rounds": ["rebuttal": true]]))
        let v = try r.passed()
        #expect((v["votes"] as? [[String: Any]])?.count == 3)
        for kind in ["codex", "claude", "hermes"] {
            #expect(r.observations(kind, "probe").count == 1)
        }
        for name in ["a", "b", "c"] {
            #expect(r.observations(name, "blind").count == 1)
            #expect(r.observations(name, "rebuttal").count == 1)
        }
        #expect(try r.ledger("SELECT seat,reason,count(*) FROM preflights GROUP BY seat,reason ORDER BY seat;") ==
                [["a", "ok", "1"], ["b", "ok", "1"], ["c", "ok", "1"]])
        #expect(try r.sql("SELECT count(*) FROM sittings;") == "1\n")
        #expect(try r.sql("SELECT count(*) FROM seat_runs;") == "6\n")
    }

    // Acceptance 11: an unavailable non-recused synthesizer prevents opening.
    @Test func signedOutSynthesizerRefusesBeforeAnyWorkRows() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["seats": ["a", "c", "d"], "synthesizer": "b"]))
        try r.put("claude.signed-out")
        try r.failure(r.wake(), exit: 4, contains: ["failed: preflight:", "b not_logged_in"])
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='b';") == "not_logged_in\n")
        #expect(try r.sql("SELECT outcome FROM requests;") == "failed\n")
        try r.noWork()
    }

    // Acceptance 13: standalone opencode runs share one gate even in a blind round.
    @Test func opencodeSeatIntervalsDoNotOverlapAndCouncilCompletes() throws {
        let r = try U25Rig()
        let seats = [u6aSeat("a", "opencode", extra: ["model": "harbor/free", "vendor": "harbor"]),
                     u6aSeat("b", "opencode", extra: ["model": "lumen/free", "vendor": "lumen"])]
        try r.configure(seats: seats, council: u7aCouncil(["seats": ["a", "b"]]))
        try r.put("opencode.models", "harbor/free\nlumen/free\n")
        for name in ["a", "b"] { try r.put(name + ".blind.delay", "2") }
        _ = try r.passed()
        let intervals = try ["a", "b"].map { name -> (Double, Double) in
            #expect(r.observations(name, "blind").count == 1)
            let start = try #require(Double(r.observation(name, "blind", suffix: "start")
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            let end = try #require(Double(r.observation(name, "blind", suffix: "end")
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(end - start >= 1)
            return (start, end)
        }.sorted { $0.0 < $1.0 }
        #expect(intervals[0].1 <= intervals[1].0)
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE exit_code=0;") == "2\n")
    }

    // Acceptance 16: only real, parseable participation counts as a success.
    @Test func unavailableSeatHasNoRunAndUnparsableRepliesHaveFailureExits() throws {
        let r = try U25Rig()
        // A healthy spare makes the panel viable; c must never acquire a seat run.
        try FileManager.default.removeItem(at: r.base.bin.appendingPathComponent("hermes"))
        try r.configure(council: u7aCouncil(["spare": ["d"]]))
        try r.reply("b", answer: "unparsable harbor answer")
        _ = try r.passed()
        #expect(try r.sql("SELECT exit_code FROM seat_runs WHERE seat='a';") == "0\n")
        let failed = try r.ledger("SELECT exit_code FROM seat_runs WHERE seat='b';")
        #expect(!failed.isEmpty && failed.allSatisfy { $0 == ["1"] })
        #expect(r.observations("b", "blind").count == 2)
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE seat='c';") == "0\n")
        #expect(try r.sql("SELECT reason FROM preflights WHERE seat='c';") == "not_installed\n")
        // Read the public U11 scoreboard over this broker's real ledger, never seed score rows.
        let ledger = try Ledger(directory: r.home.url)
        let scores = try OutcomeBook(ledger: ledger).scoreboard(now: Date())
        let a = try #require(scores.first { $0.seat == "a" && $0.council == "panel" })
        #expect(a.participation == Share(1, of: 1))
        #expect(!scores.contains { $0.seat == "c" })
    }
}
