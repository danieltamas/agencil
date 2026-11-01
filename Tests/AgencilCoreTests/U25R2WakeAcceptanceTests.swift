import Foundation
import Testing

/// U25 review round 2, findings 4, 5 and 7 (docs/U25-SPEC.md section 3, "Wake gate").
@Suite(.serialized)
struct U25R2WakeAcceptanceTests {
    private func opencodeSeats() -> [[String: Any]] {
        [u6aSeat("a", "opencode", extra: ["model": "harbor/free", "vendor": "harbor", "cap": ["seconds": 30, "tokens": 37]]),
         u6aSeat("b", "opencode", extra: ["model": "lumen/free", "vendor": "lumen", "cap": ["seconds": 30, "tokens": 37]])]
    }

    // Finding 4: a stop while one opencode seat waits on the gate ends the waiter "stopped"; it never launches.
    @Test func stopWhileSecondOpencodeSeatWaitsOnGateNeverLaunchesIt() throws {
        let r = try U25Rig()
        try r.configure(seats: opencodeSeats(), council: u7aCouncil(["seats": ["a", "b"], "deadline_seconds": 30]))
        try r.put("opencode.models", "harbor/free\nlumen/free\n")
        for name in ["a", "b"] { try r.put(name + ".blind.delay", "20") }
        try r.put("stop.brief", "change_kind: design\nquestion: inspect\nauthor_vendor: google\n")
        let pending = try r.cli(["wake", "panel", "--brief", r.control.appendingPathComponent("stop.brief").path,
                                 "--wait", "0", "--json"], exit: 2)
        let id = try #require(try r.data(brokerJSON(Data(pending.0.utf8)))["sitting"] as? String)
        try brokerPoll(15) { r.observations(nil, "blind").count == 1 }
        // Give the second seat time to be waiting on the gate, then stop the council.
        usleep(800_000)
        #expect(r.observations(nil, "blind").count == 1)
        _ = try r.cli(["stop", id, "--json"], exit: 0)
        _ = try r.cli(["result", id, "--wait", "15", "--json"], exit: 4)
        // Let the gate pass to the waiter, which must not launch.
        usleep(1_500_000)
        #expect(r.observations(nil, "blind").count == 1)
        let rows = try r.ledger("SELECT t.seat, e.state, e.reason FROM exchanges e JOIN threads t ON t.id = e.thread_id ORDER BY t.seat;")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0[1] == "failed" && $0[2] == "stopped" })
    }

    // Finding 5: a seat that wakes a council with cold standings, with one place in the broker, is not refused busy.
    @Test func seatWakingCouncilWithColdStandingsGivesItsPlaceToTheProbes() throws {
        let r = try U25Rig()
        try r.installChildWakeStubs()
        var seats = u25Seats(); seats[0]["cap"] = ["seconds": 60, "tokens": 37]
        try r.configure(seats: seats, council: u7aCouncil(["seats": ["b", "c"]]),
                        routes: [u6aRoute("a"), u6aRoute("panel", callers: ["owner", "a"])],
                        raw: ["limits": u6aText(["seats_at_once": 1])])
        try r.put("codex.ask", "parent finished")
        try r.put("codex.ask.child")
        try r.put("child.brief", "change_kind: design\nquestion: child inspect\n")
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "0\n")
        let reply = try r.data(r.request("ask", ["target": "a", "question": "parent", "wait_seconds": 40]))
        #expect(reply["state"] as? String == "answered")
        let exit = try r.observation("codex", "ask", suffix: "child-exit")
        let child = try r.observation("codex", "ask", suffix: "child")
        let error = try r.observation("codex", "ask", suffix: "child-error")
        #expect(!(child + error).lowercased().contains("busy"))
        #expect(exit == "0")
        #expect(try r.ledger("SELECT seat,reason FROM preflights ORDER BY seat;") == [["b", "ok"], ["c", "ok"]])
    }

    // Finding 7: every synthesizer of the author's vendor refuses the wake before any row or process.
    @Test(arguments: [["a"], ["a", "d"]])
    func everySynthesizerOfAuthorsVendorRefusesBeforeAnyWork(synthesizers: [String]) throws {
        let r = try U25Rig()
        var seats = u25Seats(); seats[3]["vendor"] = "harbor"
        try r.configure(seats: seats, council: u7aCouncil(["seats": ["b", "c"], "synthesizer": synthesizers]))
        let before = r.invocations()
        try r.failure(r.wake(authorVendor: "harbor"), exit: 4,
                      contains: ["failed: preflight: every synthesizer is of the author's vendor"])
        #expect(r.invocations() == before)
        #expect(try r.sql("SELECT outcome FROM requests;") == "failed\n")
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "0\n")
        try r.noWork()
    }

    // Finding 7, control: one synthesizer of another vendor keeps the wake open.
    @Test func synthesizerOfAnotherVendorStillSits() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["seats": ["b", "c"], "synthesizer": ["a", "d"]]))
        let v = try r.verdict(r.wake(authorVendor: "harbor"))
        #expect(v["state"] as? String == "done")
        #expect(try r.sql("SELECT seat FROM preflights ORDER BY seat;") == "b\nc\nd\n")
    }
}
