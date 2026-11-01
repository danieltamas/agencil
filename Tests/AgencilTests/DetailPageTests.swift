import AgencilCore
import Foundation
import Testing
@testable import Agencil

/// The detail screens in the words they show (docs/DESIGN.md, docs/AGENT-API.md "detail"): a figure the ledger does not
/// hold reads "unknown", never a guessed zero, and no screen shows a raw JSON blob.
@Suite struct DetailPageTests {
    private func panel(threads: [[String: Any]] = [], sittings: [[String: Any]] = []) throws -> PanelData {
        try PanelData(json: [
            "configured": true,
            "seats": ["total": 0, "up": 0, "thinking": 0, "items": [[String: Any]]()],
            "threads": threads, "sittings": sittings, "findings": [[String: Any]](), "proposals_pending": 0,
            "week": ["spend_usd": 0], "live": 0,
        ])
    }

    private func threadRow(state: String = "answered", reason: String? = nil, ended: String? = "2030-01-01T12:00:07Z") throws -> PanelData.Thread {
        var json: [String: Any] = ["id": "th_00000000000000aa", "caller": "maya", "seat": "a", "question": "Is it safe?", "state": state,
                                   "started": "2030-01-01T12:00:00Z"]
        if let reason { json["reason"] = reason }
        if let ended { json["ended"] = ended }
        return try panel(threads: [json]).threads[0]
    }

    private func sittingRow(state: String = "PASS", verdict: String? = "PASS", cost: Double = 0) throws -> PanelData.Sitting {
        var json: [String: Any] = ["id": "sit_00000000000000bb", "no": 3, "council": "checkout", "state": state, "round": "synthesis",
                                   "started": "2030-01-01T12:00:00Z", "cost_usd": cost]
        if state != "running" { json["ended"] = "2030-01-01T12:02:05Z" }
        if let verdict { json["verdict"] = verdict }
        return try panel(sittings: [json]).sittings[0]
    }

    private func value(_ page: DetailPage, _ name: String) -> String? { page.facts.first { $0.name == name }?.value }
    /// The digits of a grouped figure: the separator follows the machine's locale, the figure does not.
    private func digits(_ text: String?) -> String { (text ?? "").filter(\.isNumber) }
    private func section(_ page: DetailPage, _ heading: String) -> DetailPage.Section? { page.sections.first { $0.heading == heading } }

    // MARK: thread

    @Test func aThreadBeforeItsDetailArrivesIsLoadingAndEveryUnrecordedFigureIsUnknown() throws {
        let page = DetailPage.thread(try threadRow(), detail: nil)
        #expect(page.loading)
        #expect(page.kind == .thread)
        #expect(value(page, "Asked by") == "maya")
        #expect(value(page, "Seat") == "a")
        for name in ["Project", "Model", "Tokens", "Cost"] { #expect(value(page, name) == "unknown", "\(name)") }
        #expect(section(page, "Question")?.text == "Is it safe?")
    }

    @Test func responseTimeIsTheRowsDurationAndALiveThreadSaysSo() throws {
        #expect(value(DetailPage.thread(try threadRow(), detail: nil), "Response time") == "7s")
        #expect(value(DetailPage.thread(try threadRow(ended: "2030-01-01T12:02:05Z"), detail: nil), "Response time") == "2m 5s")
        let live = DetailPage.thread(try threadRow(state: "asking", ended: nil), detail: nil)
        #expect(value(live, "Response time") == "still running")
        #expect(live.live)
    }

    @Test func aThreadWithNoReportedCostOrTokensStaysUnknownNotZero() throws {
        let detail = ThreadDetail(json: ["model": "harbor-model", "harness": "codex", "project": "checkout  ~/Sites/checkout",
                                         "exchanges": [["question": "Is it safe?", "answer": "yes", "state": "answered"]]])
        let page = DetailPage.thread(try threadRow(), detail: detail)
        #expect(!page.loading)
        #expect(value(page, "Tokens") == "unknown")
        #expect(value(page, "Cost") == "unknown")
        #expect(value(page, "Model") == "harbor-model (codex)")
        #expect(value(page, "Project") == "checkout  ~/Sites/checkout")
    }

    @Test func reportedFiguresAreSummedAndAReportedZeroIsNotUnknown() throws {
        let two = ThreadDetail(json: ["exchanges": [
            ["question": "q1", "answer": "a1", "state": "answered", "cost_usd": 0.25, "tokens": 1200],
            ["question": "q2", "answer": "a2", "state": "answered", "cost_usd": 0.5, "tokens": 300],
        ]])
        let page = DetailPage.thread(try threadRow(), detail: two)
        #expect(value(page, "Cost") == "$0.75")
        #expect(digits(value(page, "Tokens")) == "1500")
        let zero = ThreadDetail(json: ["exchanges": [["question": "q", "answer": "a", "state": "answered", "cost_usd": 0.0, "tokens": 0]]])
        let free = DetailPage.thread(try threadRow(), detail: zero)
        #expect(value(free, "Cost") == "$0.00")
        #expect(value(free, "Tokens") == "0")
    }

    @Test func exchangesAreNumberedOnlyWhenThereAreSeveralAndJSONAnswersAreReadable() throws {
        let one = DetailPage.thread(try threadRow(), detail: ThreadDetail(json: ["exchanges": [["question": "q", "answer": "plain", "state": "answered"]]]))
        #expect(one.sections.map(\.heading) == ["Question", "Answer"])
        let many = ThreadDetail(json: ["exchanges": [
            ["question": "first", "answer": "{\"vote\":\"approve\"}", "state": "answered"],
            ["question": "second", "answer": "second answer", "state": "answered"],
        ]])
        let page = DetailPage.thread(try threadRow(), detail: many)
        #expect(page.sections.map(\.heading) == ["Question 1", "Answer 1", "Question 2", "Answer 2"])
        #expect(section(page, "Answer 1")?.text == "Vote: approve")
        #expect(section(page, "Answer 2")?.text == "second answer")
    }

    @Test func aFailedThreadShowsItsReasonInRedAndAStoppedOneInOrange() throws {
        let failed = DetailPage.thread(try threadRow(state: "failed", reason: "endpoint closed"), detail: nil)
        #expect(failed.state == "Failed" && failed.tone == .crit)
        #expect(section(failed, "Why it failed")?.text == "endpoint closed")
        #expect(section(failed, "Why it failed")?.tone == .crit)
        let stopped = DetailPage.thread(try threadRow(state: "failed", reason: "stopped"), detail: nil)
        #expect(stopped.state == "Stopped" && stopped.tone == .warn)
        let detail = ThreadDetail(json: ["exchanges": [["question": "q", "state": "failed", "reason": "seat exited 17"]]])
        let withDetail = DetailPage.thread(try threadRow(state: "failed", reason: "seat exited 17"), detail: detail)
        #expect(section(withDetail, "Why it failed")?.text == "seat exited 17")
        #expect(section(withDetail, "Answer") == nil)
    }

    @Test func threadToneFollowsTheOneMapping() throws {
        #expect(DetailPage.thread(try threadRow(), detail: nil).tone == .ok)
        #expect(DetailPage.thread(try threadRow(state: "asking", ended: nil), detail: nil).tone == .running)
        #expect(DetailPage.thread(try threadRow(state: "failed", reason: "x"), detail: nil).tone == .crit)
    }

    // MARK: sitting

    private func sittingDetail(_ extra: [String: Any] = [:]) -> SittingDetail {
        var json: [String: Any] = [
            "brief": "change_kind: design\nquestion: inspect", "project": "checkout  ~/Sites/checkout", "repo": "/work/checkout",
            "change_kind": "design", "diff_range": "main..topic", "snapshot": "snap_1",
            "verdict": ["verdict": "BLOCK", "rule": "any_blocker", "reasons": ["blocker AG-1-1", "second reason"],
                        "votes": [["seat": "a", "state": "done", "vote": "block"], ["seat": "b", "state": "failed"]],
                        "claims": [["id": "AG-1-1", "seat": "a", "severity": "p1", "file": "src/pay.swift", "line": 12,
                                    "evidence": "double charge", "fix": "idempotency key", "confidence": 0.9,
                                    "backers": ["b"], "dissenters": ["c"], "minority": false, "refuted": false]]],
            "rounds": [["round": "blind", "seats": [
                ["seat": "a", "state": "answered", "answer": "{\"vote\":\"block\"}", "model": "m-1", "harness": "codex",
                 "started": "2030-01-01T12:00:00Z", "ended": "2030-01-01T12:00:09Z", "cost_usd": 0.1, "tokens": 2000],
                ["seat": "b", "state": "failed", "reason": "usage limit"],
                ["seat": "c", "state": "asking"],
                ["seat": "d", "state": "failed"],
            ]]],
        ]
        json.merge(extra) { _, new in new }
        return SittingDetail(json: json)
    }

    @Test func aSittingBeforeItsDetailArrivesIsLoadingWithUnknownFigures() throws {
        let page = DetailPage.sitting(try sittingRow(), detail: nil)
        #expect(page.loading && page.kind == .sitting)
        #expect(page.title == "checkout sitting 3")
        for name in ["Project", "Repo", "Tokens", "Cost", "Rule", "Snapshot"] { #expect(value(page, name) == "unknown", "\(name)") }
        #expect(value(page, "Elapsed") == "2m 5s")
        #expect(value(DetailPage.sitting(try sittingRow(cost: 1.5), detail: nil), "Cost") == "$1.50")
    }

    @Test func aSittingShowsBriefVerdictReasonsVotesRoundsAndClaims() throws {
        let page = DetailPage.sitting(try sittingRow(verdict: "BLOCK"), detail: sittingDetail())
        #expect(!page.loading)
        #expect(section(page, "Brief")?.text.contains("inspect") == true)
        let verdict = try #require(section(page, "Verdict: BLOCK"))
        #expect(verdict.text == "- blocker AG-1-1\n- second reason")
        #expect(verdict.tone == .crit)
        #expect(page.seats.map(\.name) == ["a", "b"])
        #expect(page.seats.map(\.value) == ["block", "failed"])
        #expect(value(page, "Rule") == "any_blocker")
        #expect(value(page, "Snapshot") == "snap_1")
        #expect(value(page, "Diff") == "main..topic")
        #expect(digits(value(page, "Tokens")) == "2000")
        #expect(value(page, "Cost") == "$0.10")
        #expect(page.rounds.map(\.name) == ["Blind"])
        let claim = try #require(page.claims.first)
        #expect(claim.severity == "P1" && claim.place == "src/pay.swift:12" && claim.claim == "double charge")
        #expect(claim.fix == "idempotency key" && claim.confidence == "90%")
        #expect(claim.backers == 1 && claim.dissent == 1)
        #expect(claim.voices == "raised by a; backed by b; disputed by c")
    }

    @Test func eachRoundAnswerIsReadableAndFallsBackToTheReasonThenAPlaceholder() throws {
        let answers = try #require(DetailPage.sitting(try sittingRow(), detail: sittingDetail()).rounds.first?.answers)
        #expect(answers.map(\.seat) == ["a", "b", "c", "d"])
        #expect(answers[0].text == "Vote: block")
        #expect(answers[0].meta.contains("m-1 (codex)") && answers[0].meta.contains("9s") && answers[0].meta.contains("$0.10"))
        #expect(answers[0].tone == .ok)
        #expect(answers[1].text == "usage limit" && answers[1].tone == .crit)
        #expect(answers[2].text == "Thinking..." && answers[2].tone == .running)
        #expect(answers[3].text == "No answer recorded.")
        for answer in answers { #expect(!answer.text.contains("{") && !answer.text.contains("}")) }
    }

    @Test func sittingToneFollowsVerdictAndAStoppedSittingIsOrangeNotRed() throws {
        #expect(DetailPage.sitting(try sittingRow(verdict: "PASS"), detail: nil).tone == .ok)
        #expect(DetailPage.sitting(try sittingRow(verdict: "BLOCK"), detail: nil).tone == .crit)
        #expect(DetailPage.sitting(try sittingRow(verdict: "INCOMPLETE"), detail: nil).tone == .warn)
        #expect(DetailPage.sitting(try sittingRow(state: "running", verdict: nil), detail: nil).tone == .running)
        let stopped = DetailPage.sitting(try sittingRow(state: "failed", verdict: nil), detail: SittingDetail(json: ["reason": "stopped"]))
        #expect(stopped.state == "Stopped" && stopped.tone == .warn)
        #expect(section(stopped, "Why it ended")?.text == "stopped")
    }

    @Test func aClaimWithoutAFileHasNoPlaceAndNoFixOrConfidenceWhenNoneWasGiven() throws {
        let detail = SittingDetail(json: ["verdict": ["verdict": "PASS", "claims": [["id": "AG-1-2", "seat": "b", "severity": "p3", "evidence": "nit"]]]])
        let claim = try #require(DetailPage.sitting(try sittingRow(), detail: detail).claims.first)
        #expect(claim.place == "" && claim.fix == nil && claim.confidence == nil && claim.claim == "nit")
    }

    // MARK: finding

    @Test func aFindingPageCarriesToneFromSeverityAndOmitsAnAbsentFix() {
        let base = DemoPanel.Finding(id: "AG-1-1", severity: "P1", place: "a.swift:1", claim: "bug", backers: 2, dissent: 1)
        let red = DetailPage.finding(base)
        #expect(red.kind == .finding && red.tone == .crit && red.state == "P1")
        #expect(red.sections.map(\.heading) == ["Claim"])
        #expect(value(red, "Confidence") == "unknown" && value(red, "Backers") == "2" && value(red, "Dissent") == "1")
        let orange = DetailPage.finding(DemoPanel.Finding(id: "x", severity: "P2", place: "p", claim: "c", backers: 0, dissent: 0,
                                                         fix: "do it", confidence: "70%"))
        #expect(orange.tone == .warn && orange.sections.map(\.heading) == ["Claim", "Fix"] && value(orange, "Confidence") == "70%")
        #expect(DetailPage.finding(DemoPanel.Finding(id: "y", severity: "P3", place: "p", claim: "c", backers: 0, dissent: 0)).tone == .unknown)
    }

    @Test func aPanelFindingRowShowsPartsNotTheJSONBlob() throws {
        let body = "{\"evidence\":\"double charge\",\"fix\":\"use a key\",\"confidence\":0.8}"
        let json: [String: Any] = ["id": "AG-1-1", "severity": "p1", "file": "pay.swift", "line": 4, "body": body, "backers": 1,
                                   "dissenters": 0, "minority": false, "disposition": "open"]
        let data = try PanelData(json: [
            "configured": true, "seats": ["total": 0, "up": 0, "thinking": 0, "items": [[String: Any]]()], "threads": [[String: Any]](),
            "sittings": [[String: Any]](), "findings": [json], "proposals_pending": 0, "week": ["spend_usd": 0], "live": 0,
        ])
        let finding = DemoPanel.Finding(data.findings[0])
        #expect(finding.claim == "double charge" && finding.fix == "use a key" && finding.confidence == "80%")
        #expect(!finding.claim.contains("{"))
    }
}
