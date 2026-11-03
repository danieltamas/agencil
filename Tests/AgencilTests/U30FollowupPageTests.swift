import AgencilCore
import Foundation
import Testing
@testable import Agencil

func u30DetailJSON(state: String = "answered", seats: [String] = ["b", "a", "d"],
                   turns: Int = 1, answer: String = "## Answer\n**Keep the boundary.**") -> [String: Any] {
    var json = u29DetailJSON(summary: "## Answer\nThe sitting is finished.")
    json["state"] = "done"
    json["follow_up_seats"] = seats
    json["follow_up_default"] = "d"
    json["followups"] = [[
        "seat": "d", "thread": "th_followup", "model": "harbor-model", "harness": "opencode",
        "exchanges": (1...max(1, turns)).map { index -> [String: Any] in
            var exchange: [String: Any] = ["seq": index, "question": "Owner question \(index)", "state": state,
                "tokens": 12, "tokens_in": 8, "tokens_out": 4, "cost_usd": 0.25, "cost_note": "reported",
                "started": "2030-01-01T12:00:00Z", "ended": "2030-01-01T12:00:07Z"]
            if state == "answered" { exchange["answer"] = answer }
            return exchange
        }
    ]]
    return json
}

@Suite(.serialized) @MainActor struct U30FollowupPageTests {
    // A9: actual decoding and page transformation, including each eligibility boundary.
    @Test func sittingMapsFollowupTurnsMetadataEligibilityAndLiveState() throws {
        let row = try #require(u29PanelData().sittings.first)
        let json = u30DetailJSON(turns: 2)
        let detail = SittingDetail(json: json)
        let page = DetailPage.sitting(row, detail: detail)
        #expect(page.canFollowUp)
        #expect(!page.live)
        #expect(page.followUpSeats == ["b", "a", "d"] && page.followUpDefault == "d")
        let followup = try #require(page.followups.first)
        #expect(page.followups.count == 1 && followup.seat == "d")
        #expect(followup.turns.count == 2)
        #expect(followup.turns.map(\.question) == ["Owner question 1", "Owner question 2"])
        for turn in followup.turns {
            #expect(turn.answer == "## Answer\n**Keep the boundary.**")
            #expect(turn.meta.contains("harbor-model") && turn.meta.contains("opencode"))
            #expect(turn.meta.contains(PanelFormat.money(0.25)))
            #expect(!turn.meta.isEmpty)
        }
        #expect(!DetailPage.sitting(row, detail: nil).canFollowUp)
        #expect(!DetailPage.sitting(row, detail: SittingDetail(json: u30DetailJSON(seats: []))).canFollowUp)
        let runningData = try PanelData(json: [
            "configured": true, "seats": ["total": 0, "up": 0, "thinking": 0, "items": [[String: Any]]()],
            "threads": [[String: Any]](), "findings": [[String: Any]](), "proposals_pending": 0,
            "week": ["spend_usd": 0], "live": 1,
            "sittings": [["id": "sit_harbor", "no": 1, "council": "panel", "question": "Is harbor ready?",
                          "state": "running", "round": "blind", "cost_usd": 0,
                          "started": "2030-01-01T12:00:00Z"]]
        ])
        let running = try #require(runningData.sittings.first)
        var runningJSON = json; runningJSON["state"] = "running"
        #expect(!DetailPage.sitting(running, detail: SittingDetail(json: runningJSON)).canFollowUp)
        let asking = DetailPage.sitting(row, detail: SittingDetail(json: u30DetailJSON(state: "asking")))
        #expect(asking.live)
        #expect(asking.followups.first?.turns.first?.answer == "Thinking...")
    }

    // A10: hold only external transport, exercising the real action and store state.
    @Test func storeFollowupIsSingleFlightTrimsAndRetainsDraftAcrossRefreshAndRefusal() async throws {
        let store = PanelStore(data: try u29PanelData())
        let wire = U30PanelWire()
        store.brokerRequest = { request in try await wire.send(request) }
        store.detailReader = { _ in
            wire.reads += 1
            var json = u30DetailJSON(state: wire.accepted ? "asking" : "answered")
            if wire.accepted {
                json["followups"] = [["seat": "a", "thread": "th_followup", "model": "harbor-model", "harness": "codex",
                    "exchanges": [["seq": 1, "question": "Why keep this boundary?", "state": "asking"]]]]
            }
            return json
        }
        store.open(sitting: "sit_harbor")
        try await wait { store.detail?.loading == false }
        #expect(store.followUp?.seat == "d")
        store.followUp?.seat = "a"
        store.followUp?.text = " \n Why keep this boundary? \t"
        #expect(store.canSendFollowUp)
        let draft = store.followUp
        store.open(sitting: "sit_harbor")
        try await wait { store.detail?.loading == false }
        #expect(store.followUp == draft, "A detail refresh retains both unsent fields")
        let reads = wire.reads
        wire.hold = true
        let completion = U30PanelCompletion()
        let first = Task { await store.sendFollowUpAction()(); completion.done = true }
        defer { wire.release(); first.cancel() }
        try await wait { wire.requests.count == 1 }
        #expect(!completion.done)
        await store.sendFollowUp()
        #expect(wire.requests.count == 1)
        let request = try #require(wire.requests.first)
        #expect(request["op"] as? String == "followup")
        #expect(request["caller"] as? String == "owner")
        #expect(request["sitting"] as? String == "sit_harbor")
        #expect(request["council"] as? Bool == true)
        #expect(request["seat"] == nil)
        #expect(request["question"] as? String == "Why keep this boundary?")
        wire.release()
        try await wait { completion.done }
        #expect(store.followUp?.text == "" && store.followUp?.seat == "a")
        #expect(wire.reads > reads)
        #expect(store.detail?.live == true)
        #expect(store.detail?.followups.first?.seat == "a")
        #expect(store.detail?.followups.first?.turns.first?.question == "Why keep this boundary?")
        #expect(store.detail?.followups.first?.turns.first?.answer == "Thinking...")
        #expect(store.followUpProblem == nil)
        store.followUp?.text = " \n\t "
        #expect(!store.canSendFollowUp)
        await store.sendFollowUp()
        #expect(wire.requests.count == 1)
        wire.hold = false
        wire.refusal = "refused: budget"
        store.followUp?.text = " Keep this unsent text. "
        let refusedDraft = store.followUp
        await store.sendFollowUp()
        #expect(wire.requests.count == 2)
        #expect(store.followUp == refusedDraft)
        #expect(store.followUpProblem == "refused: budget")
        store.open(sitting: "sit_harbor")
        try await wait { store.detail?.loading == false }
        #expect(store.followUp == refusedDraft)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw U30PageHang() }
            await Task.yield()
        }
    }
}

private struct U30PageHang: Error {}
@MainActor private final class U30PanelCompletion { var done = false }
@MainActor private final class U30PanelWire {
    var requests: [[String: Any]] = []
    var reads = 0
    var hold = false
    var accepted = false
    var refusal: String?
    private var pending: CheckedContinuation<Void, Never>?

    func send(_ request: [String: Any]) async throws -> [String: Any] {
        #expect(request["op"] as? String == "followup")
        requests.append(request)
        if hold { await withCheckedContinuation { pending = $0 } }
        if let refusal { throw PanelClient.Refused(message: refusal) }
        accepted = true
        return ["sitting": "sit_harbor", "thread": "th_followup", "seat": "a", "seq": 1]
    }
    func release() { pending?.resume(); pending = nil }
}
