@testable import AgencilCore
import Darwin
import Foundation
import Testing

// External seats, real broker, real ledger. No production prompt builder is used.
// R1: embedded owner labels survive detail and panel display.
// R2: a failed first follow-up retries with full evidence on the same thread.
private final class U30Rig {
    let r: U7aRig
    let council = u7aCouncil(["seats": ["b", "a"], "spare": ["c"], "synthesizer": "d"])
    let closing = "Answer in Markdown prose for the owner. Do not answer in JSON."

    init(panel: Bool = true) throws {
        r = try U7aRig()
        try configure()
        try restart(panel: panel)
    }

    func askReplies(_ text: String = "## Follow-up answer\nKeep the boundary explicit.") throws {
        for kind in ["codex", "claude", "hermes", "opencode"] {
            try r.put(kind + ".ask", text)
        }
    }

    func configure(_ value: [String: Any]? = nil, routes: [[String: Any]] = [],
                   raw: [String: String] = [:], councils: Any? = nil) throws {
        try r.configure(value ?? council, routes: routes, raw: raw, councils: councils)
    }

    func restart(panel: Bool) throws {
        let broker = try #require(r.base.broker)
        var env = try #require(broker.process.environment)
        if panel { env["AGENCIL_TEST_APP_PEER"] = String(getpid()) }
        else { env.removeValue(forKey: "AGENCIL_TEST_APP_PEER") }
        broker.kill(); _ = try broker.finish()
        r.base.broker = try r.home.serve(env)
    }

    func finished(synthesis: Bool = true, rebuttal: Bool = false) throws -> String {
        var value = council
        if !synthesis { value.removeValue(forKey: "synthesizer") }
        value["rounds"] = ["rebuttal": rebuttal]
        // Only setup needs a route; the follow-up itself must use its implicit route.
        try configure(value, routes: [u6aRoute("panel")])
        try askReplies("OK")
        let verdict = try r.decided("PASS")
        try configure(value)
        try askReplies()
        return try #require(verdict["sitting"] as? String)
    }

    func request(_ id: String, _ text: String = "What should we check next?", seat: String? = nil,
                 extra: [String: Any] = [:]) throws -> [String: Any] {
        var fields: [String: Any] = ["op": "followup", "caller": "owner", "sitting": id, "question": text]
        if let seat { fields["seat"] = seat }
        return try r.home.request(fields.merging(extra) { _, new in new })
    }

    func data(_ reply: [String: Any]) throws -> [String: Any] { try r.base.data(reply) }
    func detail(_ id: String) throws -> [String: Any] {
        try data(r.home.request(["op": "detail", "id": id]))
    }
    func rows(_ data: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(data[key] as? [[String: Any]])
    }
    func answered(_ thread: String, seq: Int = 1) throws {
        try brokerPoll(20) {
            let turns = try self.rows(self.detail(thread), "exchanges")
            return turns.count == seq && turns.last?["state"] as? String == "answered"
        }
    }
    func counts() throws -> String {
        try r.sql("SELECT (SELECT count(*) FROM threads), (SELECT count(*) FROM exchanges), (SELECT count(*) FROM runs);")
    }
    func failure(_ reply: [String: Any], exit: Int, message: String? = nil) throws {
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == exit)
        let error = try #require(reply["error"] as? String)
        if let message { #expect(error == message) }
        else { #expect(!error.isEmpty) }
    }
    func unchanged(_ before: String, observations: Int) throws {
        #expect(try counts() == before)
        #expect(r.observations().count == observations)
    }
    func mutate(_ sql: String, _ bindings: [String] = []) throws {
        let ledger = try Ledger(directory: r.home.url)
        try ledger.locked { try ledger.run(sql, bindings) }
    }
    func ordered(_ text: String, _ markers: [String]) throws {
        var start = text.startIndex
        for marker in markers {
            let range = try #require(text.range(of: marker, range: start..<text.endIndex), "Missing or unordered: \(marker)")
            start = range.upperBound
        }
    }
}

@Suite(.serialized) struct U30FollowupAcceptanceTests {
    // A1: inspect the actual confined seat's prompt and the real link row.
    @Test func panelFollowupWithoutRoutePersistsThreadAndOrderedEvidencePacket() throws {
        let f = try U30Rig(), r = f.r
        let claim = u7aClaim("p3", evidence: "CLAIM_START\nCLAIM_END")
        for seat in ["a", "b"] {
            try r.reply(seat, try u6aText(["vote": "approve", "claims": [], "assessments": [], "notes": "EARLY_" + seat]))
            try r.reply(seat, "rebuttal", try u6aText(["vote": "approve", "claims": seat == "a" ? [claim] : [],
                                                      "assessments": [], "notes": "FINAL_" + seat]))
        }
        let id = try f.finished(rebuttal: true)
        let text = "Explain the remaining risk."
        let reply = try f.data(f.request(id, text))
        let thread = try #require(reply["thread"] as? String)
        #expect(reply["sitting"] as? String == id)
        #expect(reply["seat"] as? String == "d")
        #expect(reply["seq"] as? Int == 1)
        try f.answered(thread)
        #expect(try r.sql("SELECT sitting_id,round FROM thread_rounds WHERE thread_id='\(thread)';") == id + "|followup\n")
        let prompt = try r.text(#require(r.observations("opencode", "ask").last))
        #expect(prompt.hasPrefix("FOLLOW-UP ON SITTING " + id))
        #expect(prompt.hasSuffix(f.closing))
        try f.ordered(prompt, ["QUESTION OF THE SITTING:", "inspect packet", "SYNTHESIS:", "SUMMARY_MARKER",
                               "FINAL ANSWERS OF THE SEATS:", "VERDICT:", "PASS",
                               "OWNER'S FOLLOW-UP:", text, f.closing])
        let answersStart = try #require(prompt.range(of: "FINAL ANSWERS OF THE SEATS:")).upperBound
        let answersEnd = try #require(prompt.range(of: "VERDICT:", range: answersStart..<prompt.endIndex)).lowerBound
        let answers = String(prompt[answersStart..<answersEnd])
        for seat in ["a", "b"] {
            try f.ordered(answers, ["[seat \(seat)]", "FINAL_" + seat])
        }
        #expect(!prompt.contains("EARLY_a") && !prompt.contains("EARLY_b"))
        #expect(prompt.components(separatedBy: "\n").contains { $0.contains("CLAIM_START") && $0.contains("CLAIM_END") })
        #expect(prompt.lowercased().contains("evidence"))
    }

    // A2: wire owner is not identity, even with an explicit override or child capability.
    @Test func nonPanelOverrideAndSeatChildCannotStartFollowups() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        var before = try f.counts(), observations = r.observations().count
        try f.failure(f.request(id, extra: ["as": "owner"]), exit: 3,
                      message: "refused: a follow-up comes from the panel")
        try f.unchanged(before, observations: observations)
        try f.restart(panel: false)
        try f.failure(f.request(id), exit: 3, message: "refused: a follow-up comes from the panel")
        try f.unchanged(before, observations: observations)

        // Change only the installed per-test executable, never Tests/Fixtures.
        let url = r.base.bin.appendingPathComponent("codex")
        let source = try r.text(url)
        let command = "\"$STUB_CLI\" wake panel --brief \"$STUB_DIR/child.brief\" --wait 15 --json"
        try #require(source.contains(command))
        let raw = "printf '{\"op\":\"followup\",\"caller\":\"owner\",\"sitting\":\"\(id)\",\"question\":\"child question\",\"cap\":\"%s\"}\\n' \"$AGENCIL_CAP\" | /usr/bin/nc -w 30 -U \"$AGENCIL_HOME/agencil.sock\""
        try source.replacingOccurrences(of: command, with: raw).write(to: url, atomically: false, encoding: .utf8)
        try f.restart(panel: true)
        try f.configure(routes: [u6aRoute("a")])
        try r.put("codex.ask.child")
        let parent = try f.data(r.base.ask("a", question: "parent"))
        let parentID = try #require(parent["thread"] as? String)
        try f.answered(parentID)
        let child = try brokerJSON(Data(r.text(#require(r.observations("codex", "ask", suffix: "child").last)).utf8))
        try f.failure(child, exit: 3, message: "refused: a follow-up comes from the panel")
        #expect(try r.sql("SELECT count(*) FROM thread_rounds WHERE round='followup';") == "0\n")
        before = try f.counts(); observations = r.observations().count
        try f.failure(f.request(id, extra: ["caller": "a"]), exit: 3,
                      message: "refused: a follow-up comes from the panel")
        try f.unchanged(before, observations: observations)
    }

    // A3: every malformed field and each state error, with no work after refusal.
    @Test func usageAndStateRefusalsHaveCorrectExitAndLeaveNoWork() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        let valid: [String: Any] = ["op": "followup", "caller": "owner", "sitting": id, "question": "why?"]
        var invalid: [[String: Any]] = []
        for key in ["sitting", "question"] {
            var missing = valid; missing.removeValue(forKey: key); invalid.append(missing)
            invalid.append(valid.merging([key: 7]) { _, new in new })
        }
        for fields in [["question": " \n\t"], ["question": String(repeating: "q", count: 8_001)],
                       ["sitting": "th_wrong"], ["seat": 7]] as [[String: Any]] {
            invalid.append(valid.merging(fields) { _, new in new })
        }
        let before = try f.counts(), observations = r.observations().count
        for request in invalid {
            try f.failure(r.home.request(request), exit: 64)
            try f.unchanged(before, observations: observations)
        }
        try f.failure(f.request("sit_missing"), exit: 4, message: "failed: unknown sitting")
        try f.failure(f.request(id, seat: "outside"), exit: 4,
                      message: "failed: outside is not a seat of council panel")
        try f.mutate("UPDATE sittings SET state='running' WHERE id=?;", [id])
        try f.failure(f.request(id), exit: 4, message: "failed: the sitting is still running")
        try f.mutate("UPDATE sittings SET state='done' WHERE id=?;", [id])
        try f.configure(councils: [])
        try f.failure(f.request(id), exit: 4, message: "failed: no council named panel")
        try f.unchanged(before, observations: observations)
    }

    // A4: explicit, synthesis author, first answer in council order, and no answers.
    @Test func seatChoiceUsesEachFallbackInOrder() throws {
        for mode in ["explicit", "summary", "answered", "first"] {
            let f = try U30Rig(), r = f.r
            let id: String
            if mode == "first" {
                let council = u7aCouncil(["seats": ["b", "a"]])
                try f.configure(council, routes: [u6aRoute("panel")])
                for seat in ["a", "b"] { try r.put(seat + ".blind.fail") }
                let v = try r.verdict(r.wake(exit: 2))
                id = try #require(v["sitting"] as? String)
                try f.configure(council)
                try f.askReplies()
            } else {
                id = try f.finished(synthesis: mode != "answered")
            }
            let expected = mode == "explicit" ? "c" : mode == "summary" ? "d" : "b"
            let reply = try f.data(f.request(id, seat: mode == "explicit" ? "c" : nil))
            #expect(reply["seat"] as? String == expected)
            try f.answered(#require(reply["thread"] as? String))
        }
    }

    // A5: the held external seat establishes overlap without a duration assertion.
    @Test func sameSeatContinuesOtherSeatOpensAndOverlapIsRejected() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        try r.put("opencode.ask.hold")
        let askCount = r.observations("opencode", "ask").count
        let first = try f.data(f.request(id, "FIRST_OWNER_TEXT"))
        let thread = try #require(first["thread"] as? String)
        try brokerPoll(15) { r.observations("opencode", "ask").count > askCount }
        let before = try f.counts(), observations = r.observations().count
        try f.failure(f.request(id, "TOO_EARLY"), exit: 4,
                      message: "failed: d is still answering the last follow-up")
        try f.unchanged(before, observations: observations)
        #expect(try f.rows(f.detail(thread), "exchanges").count == 1)
        try r.put("release")
        try f.answered(thread)
        let second = try f.data(f.request(id, "SECOND_OWNER_TEXT"))
        #expect(second["thread"] as? String == thread && second["seq"] as? Int == 2)
        try f.answered(thread, seq: 2)
        let prompt = try r.text(#require(r.observations("opencode", "ask").last))
        try f.ordered(prompt, ["ASKED:", "FIRST_OWNER_TEXT", "ANSWERED:", "Keep the boundary explicit.", "SECOND_OWNER_TEXT"])
        // The packet may occur once inside the historic transcript, never as the new question.
        #expect(prompt.components(separatedBy: "FOLLOW-UP ON SITTING " + id).count <= 2)
        let exchanges = try f.rows(f.detail(thread), "exchanges")
        #expect(exchanges[1]["question"] as? String == "SECOND_OWNER_TEXT")
        let other = try f.data(f.request(id, "OTHER_SEAT_TEXT", seat: "a"))
        let otherThread = try #require(other["thread"] as? String)
        #expect(otherThread != thread && other["seq"] as? Int == 1)
        try f.answered(otherThread)
        #expect(try r.sql("SELECT count(*) FROM thread_rounds WHERE round='followup';") == "2\n")
    }

    // A6: compare fields to the same real thread's detail, including optional accounting.
    @Test func sittingDetailExposesOwnerTurnsAccountingAndOrderedChoices() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        var threads: [String] = []
        for seat in ["d", "a"] {
            let data = try f.data(f.request(id, "Owner asks " + seat, seat: seat))
            let thread = try #require(data["thread"] as? String)
            try f.answered(thread); threads.append(thread)
        }
        // Usage is optional external information. Seed a reported usage row so
        // omitting every accounting key cannot satisfy the detail contract.
        try f.mutate("UPDATE exchanges SET tokens_in=8,tokens_out=4,cost_usd=0.25,cost_basis='reported' WHERE thread_id=? AND seq=1;", [threads[0]])
        let data = try f.detail(id), detail = SittingDetail(json: data)
        let followups = try f.rows(data, "followups")
        #expect(followups.compactMap { $0["thread"] as? String } == threads)
        #expect(followups.compactMap { $0["seat"] as? String } == ["d", "a"])
        #expect(data["follow_up_seats"] as? [String] == ["b", "a", "c", "d"])
        #expect(data["follow_up_default"] as? String == "d")
        #expect(detail.followUpSeats == ["b", "a", "c", "d"] && detail.followUpDefault == "d")
        #expect(detail.followups.count == 2)
        #expect(!(try f.rows(data, "rounds")).contains { $0["round"] as? String == "followup" })
        for (index, followup) in followups.enumerated() {
            let thread = try f.detail(threads[index])
            let exchange = try #require(f.rows(followup, "exchanges").first)
            let original = try #require(f.rows(thread, "exchanges").first)
            #expect(exchange["question"] as? String == "Owner asks " + (index == 0 ? "d" : "a"))
            #expect(exchange["state"] as? String == "answered")
            #expect(exchange["answer"] as? String == "## Follow-up answer\nKeep the boundary explicit.")
            for key in ["seq", "answer", "state", "reason", "tokens", "tokens_in", "tokens_out", "cost_usd", "cost_note"] {
                #expect(NSDictionary(dictionary: ["value": exchange[key] ?? NSNull()])
                    .isEqual(to: ["value": original[key] ?? NSNull()]), "\(key)")
            }
            #expect(detail.followups[index].thread == threads[index])
            #expect(detail.followups[index].exchanges.first?.question == exchange["question"] as? String)
            #expect(detail.followups[index].model == thread["model"] as? String)
            #expect(detail.followups[index].harness == thread["harness"] as? String)
        }
        let reported = try #require(detail.followups.first?.exchanges.first)
        #expect(reported.tokens == 12 && reported.tokensIn == 8 && reported.tokensOut == 4)
        #expect(reported.costUSD == 0.25 && reported.costNote == "reported")
        let panel = try f.data(r.home.request(["op": "panel"]))
        let listed = try f.rows(panel, "threads").compactMap { $0["id"] as? String }
        #expect(threads.allSatisfy(listed.contains))
    }

    // A7: spend a real vendor budget, then admit against its already consumed limit.
    @Test func spentVendorBudgetRefusesBeforeCreatingFollowupOrLaunchingSeat() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        let budget = u6cBudget("vendor-cap", scope: "vendor", key: "codex", tokens: 1_000_000)
        try f.configure(routes: [u6aRoute("a")], raw: ["budgets": u6aText([budget])])
        let spent = try f.data(r.base.ask("a", question: "Consume the vendor budget"))
        try f.answered(#require(spent["thread"] as? String))
        let budgets = try f.rows(f.data(r.home.request(["op": "budgets"])), "budgets")
        let used = try #require(budgets.first?["spent_tokens"] as? NSNumber).intValue
        #expect(used > 0)
        let exhausted = u6cBudget("vendor-cap", scope: "vendor", key: "codex", tokens: used)
        try f.configure(raw: ["budgets": u6aText([exhausted])])
        let before = try f.counts(), observations = r.observations().count
        let reply = try f.request(id, seat: "a")
        try f.failure(reply, exit: 3)
        #expect((reply["error"] as? String)?.hasPrefix("refused: budget") == true)
        try f.unchanged(before, observations: observations)
    }

    // A8: large recorded parts are legitimate ledger data, not a fake prompt builder.
    @Test func oversizedPacketCutsAnswersBeforeSummaryAndNeverCutsOwnerText() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        let summary = "SUMMARY_START" + String(repeating: "s", count: 39_000) + "SUMMARY_END"
        var verdict = try #require(try f.detail(id)["verdict"] as? [String: Any])
        verdict["summary"] = summary; verdict["summary_by"] = "d"
        try f.mutate("UPDATE sittings SET verdict=? WHERE id=?;", [try u6aText(verdict), id])
        for seat in ["a", "b"] {
            let answer = try u6aText(["vote": "approve", "claims": [], "assessments": [],
                                    "notes": String(repeating: seat, count: 12_000)])
            try f.mutate("UPDATE exchanges SET answer=? WHERE thread_id IN (SELECT thread_id FROM thread_rounds WHERE sitting_id=? AND round='blind') AND thread_id IN (SELECT id FROM threads WHERE seat=?);", [answer, id, seat])
        }
        let owner = "OWNER_START" + String(repeating: "q", count: 7_970) + "OWNER_END"
        let data = try f.data(f.request(id, owner))
        try f.answered(#require(data["thread"] as? String))
        let prompt = try r.text(#require(r.observations("opencode", "ask").last))
        #expect(prompt.count <= 48_000)
        #expect(prompt.contains(owner) && prompt.hasSuffix(f.closing))
        #expect(prompt.contains(summary), "Seat answers must be cut before the synthesis")
        #expect(!prompt.contains(String(repeating: "a", count: 4_001)))
        #expect(!prompt.contains(String(repeating: "b", count: 4_001)))
    }

    // A9: council fan-out keeps available seats working while an overlapping seat is skipped.
    @Test func councilFollowupFansOutAndSkipsStillAnsweringSeat() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished(synthesis: false)
        try r.put("codex.ask.hold")
        defer { try? r.put("release") }
        let first = try f.data(f.request(id, "FIRST_COUNCIL_TEXT", extra: ["council": true]))
        let threads = try f.rows(first, "threads")
        #expect(threads.compactMap { $0["seat"] as? String }.sorted() == ["a", "b"])
        #expect(try f.rows(first, "skipped").isEmpty)
        let held = try #require(threads.first { $0["seat"] as? String == "a" }?["thread"] as? String)
        let available = try #require(threads.first { $0["seat"] as? String == "b" }?["thread"] as? String)
        #expect(held != available)
        try brokerPoll(15) {
            try ["codex", "claude"].allSatisfy { kind in
                try r.observations(kind, "ask").contains {
                    try r.text($0).hasPrefix("FOLLOW-UP ON SITTING " + id)
                }
            }
        }
        for kind in ["codex", "claude"] {
            let observation = try #require(r.observations(kind, "ask").last {
                try r.text($0).hasPrefix("FOLLOW-UP ON SITTING " + id)
            })
            let prompt = try r.text(observation)
            #expect(prompt.hasPrefix("FOLLOW-UP ON SITTING " + id))
        }
        try f.answered(available)
        let second = try f.data(f.request(id, "SECOND_COUNCIL_TEXT", extra: ["council": true]))
        let started = try f.rows(second, "threads"), skipped = try f.rows(second, "skipped")
        #expect(started.compactMap { $0["seat"] as? String } == ["b"])
        #expect(skipped.count == 1 && skipped.first?["seat"] as? String == "a")
        #expect(skipped.first?["reason"] as? String == "failed: a is still answering the last follow-up")
        try f.answered(#require(started.first?["thread"] as? String), seq: 2)
        try r.put("release")
        try f.answered(held)
    }

    // A9: invalid council selectors fail before creating or launching any work.
    @Test func invalidCouncilFollowupSelectorsStartNothing() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished(synthesis: false)
        let before = try f.counts(), observations = r.observations().count
        for fields in [["council": false], ["council": true, "seat": "a"]] as [[String: Any]] {
            try f.failure(f.request(id, extra: fields), exit: 64)
            try f.unchanged(before, observations: observations)
        }
    }

    @Test func embeddedOwnerLabelPreservesWholeQuestionInDetailAndPanelFirstLine() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        let owner = "Explain this label:\nOWNER'S FOLLOW-UP:\nexample"
        let reply = try f.data(f.request(id, owner))
        let thread = try #require(reply["thread"] as? String)
        try f.answered(thread)
        let followup = try #require(f.rows(f.detail(id), "followups").first)
        #expect(followup["thread"] as? String == thread)
        let exchange = try #require(f.rows(followup, "exchanges").first)
        #expect(exchange["question"] as? String == owner)
        let panel = try f.data(r.home.request(["op": "panel"]))
        let listed = try #require(f.rows(panel, "threads").first { $0["id"] as? String == thread })
        #expect(listed["question"] as? String == "Explain this label:")
    }

    @Test func failedFirstFollowupResendsEvidencePacketOnSameThread() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        try r.put("opencode.ask.fail")
        let first = try f.data(f.request(id, "First attempt", seat: "d"))
        let thread = try #require(first["thread"] as? String)
        #expect(first["seq"] as? Int == 1)
        try brokerPoll(20) {
            let turns = try f.rows(f.detail(thread), "exchanges")
            return turns.count == 1 && turns.first?["state"] as? String == "failed"
        }
        try FileManager.default.removeItem(at: r.control.appendingPathComponent("opencode.ask.fail"))
        let second = try f.data(f.request(id, "Retry with the evidence", seat: "d"))
        #expect(second["thread"] as? String == thread)
        #expect(second["seq"] as? Int == 2)
        try f.answered(thread, seq: 2)
        let prompt = try r.text(#require(r.observations("opencode", "ask").last))
        #expect(prompt.hasPrefix("FOLLOW-UP ON SITTING " + id))
        try f.ordered(prompt, ["QUESTION OF THE SITTING:", "inspect packet", "SYNTHESIS:", "SUMMARY_MARKER",
                               "FINAL ANSWERS OF THE SEATS:", "VERDICT:", "OWNER'S FOLLOW-UP:",
                               "Retry with the evidence", f.closing])
        let exchanges = try f.rows(f.detail(thread), "exchanges")
        #expect(exchanges[0]["state"] as? String == "failed")
        #expect(exchanges[1]["state"] as? String == "answered")
    }

    // A12: new empty collection must not reclassify existing sitting or direct threads.
    @Test func noFollowupsPreservesRoundsAndExistingThreadDetail() throws {
        let f = try U30Rig(), r = f.r
        let id = try f.finished()
        let sitting = try f.detail(id)
        #expect(try f.rows(sitting, "followups").isEmpty)
        #expect(try f.rows(sitting, "rounds").compactMap { $0["round"] as? String } == ["blind", "synthesis"])
        try f.configure(routes: [u6aRoute("a")])
        let direct = try f.data(r.base.ask("a", question: "Existing direct question"))
        let thread = try #require(direct["thread"] as? String)
        try f.answered(thread)
        // Pre-link-table direct threads are still decoded by the legacy path.
        try f.mutate("DELETE FROM thread_rounds WHERE thread_id=?;", [thread])
        let before = try f.detail(thread)
        _ = try f.detail(id)
        #expect(NSDictionary(dictionary: try f.detail(thread)).isEqual(to: before))
        let decoded = ThreadDetail(json: before)
        #expect(decoded.exchanges.first?.question == "Existing direct question")
        #expect(decoded.exchanges.first?.answer == "## Follow-up answer\nKeep the boundary explicit.")
        #expect(decoded.exchanges.first?.state == "answered")
    }
}
