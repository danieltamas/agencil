import Foundation
import Testing

/// U25 review round 3, findings 2 and 3 (docs/U25-SPEC.md section 2, "Waits stop with the sitting").
@Suite(.serialized)
struct U25R3StopAcceptanceTests {
    private func opencodeSeats() -> [[String: Any]] {
        [u6aSeat("a", "opencode", extra: ["model": "harbor/free", "vendor": "harbor", "cap": ["seconds": 30, "tokens": 37]]),
         u6aSeat("b", "opencode", extra: ["model": "lumen/free", "vendor": "lumen", "cap": ["seconds": 30, "tokens": 37]])]
    }

    // Finding 2: stopping an ordinary ask that waits on the opencode gate ends it stopped, at once.
    @Test func stoppedAskWaitingBehindAnotherOpencodeRunEndsStoppedAndNeverLaunches() throws {
        let r = try U25Rig()
        let budget = u6cBudget(scope: "route", key: "b", tokens: 100000)
        try r.configure(seats: opencodeSeats(), council: u7aCouncil(["seats": ["a", "b"]]),
                        routes: [u6aRoute("a"), u6aRoute("b")], raw: ["budgets": try u6aText([budget])])
        try r.put("opencode.models", "harbor/free\nlumen/free\n")
        try r.put("opencode.ask.delay", "6")
        // Hold the first run until the stopped waiter has returned, independent of CPU load.
        let stub = r.base.bin.appendingPathComponent("opencode")
        let script = try String(contentsOf: stub, encoding: .utf8)
        let delay = "/bin/sleep \"$(/bin/cat \"$STUB_DIR/$seat.$round.delay\")\""
        try #require(script.contains(delay))
        try script.replacingOccurrences(of: delay,
            with: "while [ ! -f \"$STUB_DIR/release\" ]; do /bin/sleep 0.01; done")
            .write(to: stub, atomically: false, encoding: .utf8)
        let first = try r.data(r.request("ask", ["target": "a", "question": "first", "wait_seconds": 0]))
        let firstThread = try #require(first["thread"] as? String)
        try brokerPoll { r.observations("opencode", "ask").count == 1 }

        let outcome = U25R2Shared(value: NSMutableArray())
        let done = DispatchSemaphore(value: 0)
        let shared = U25R2Shared(value: r)
        DispatchQueue.global().async {
            let reply = try? shared.value.request("ask", ["target": "b", "question": "second", "wait_seconds": 30])
            outcome.value.add(reply ?? [:]); done.signal()
        }
        try brokerPoll { try r.ledger("SELECT id FROM threads WHERE seat = 'b';").count == 1 }
        let thread = try #require(try r.ledger("SELECT id FROM threads WHERE seat = 'b';").first?.first)
        usleep(800_000)
        #expect(r.observations("opencode", "ask").count == 1)
        _ = try r.request("stop", ["id": thread])
        try #require(done.wait(timeout: .now() + 30) == .success)
        let holderPID = try #require(Int32(r.observation("opencode", "ask", suffix: "pid")
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(brokerAlive(holderPID))
        #expect(r.observations("opencode", "ask", suffix: "end").isEmpty,
                "Stopped waiter must return before the gate holder finishes")
        let reply = try #require(outcome.value.firstObject as? [String: Any])
        let answer = try r.data(reply)
        #expect(answer["state"] as? String == "failed")
        #expect(try r.ledger("SELECT e.state, e.reason FROM exchanges e JOIN threads t ON t.id = e.thread_id WHERE t.seat = 'b';") == [["failed", "stopped"]])
        let budgets = try #require(try r.data(r.request("budgets"))["budgets"] as? [[String: Any]])
        #expect(try u6cNumber(#require(budgets.first), "reserved_tokens") == 0)
        #expect(try r.sql("SELECT count(*) FROM reservations r JOIN threads t ON t.id = r.thread_id WHERE t.seat = 'b' AND r.state = 'reserved';") == "0\n")
        // The first run ends and frees the gate; the stopped ask must not take it.
        try r.put("release")
        _ = try r.request("result", ["id": firstThread, "wait_seconds": 30])
        try brokerPoll { r.observations("opencode", "ask", suffix: "end").count == 1 }
        #expect(r.observations("opencode", "ask").count == 1)
    }

    // Finding 3: a stop of the sitting while a non-opencode seat waits for a place; it never launches afterwards.
    @Test func stoppedSittingNeverLaunchesSeatWaitingForCapacity() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["seats": ["a", "b"], "deadline_seconds": 30]),
                        raw: ["limits": try u6aText(["seats_at_once": 1])])
        for name in ["a", "b"] { try r.put(name + ".blind.delay", "20") }
        try r.put("stop.brief", "change_kind: design\nquestion: inspect\nauthor_vendor: google\n")
        let pending = try r.cli(["wake", "panel", "--brief", r.control.appendingPathComponent("stop.brief").path,
                                 "--wait", "0", "--json"], exit: 2)
        let id = try #require(try r.data(brokerJSON(Data(pending.0.utf8)))["sitting"] as? String)
        try brokerPoll(20) { r.observations(nil, "blind").count == 1 }
        usleep(800_000)
        #expect(r.observations(nil, "blind").count == 1)
        _ = try r.cli(["stop", id, "--json"], exit: 0)
        _ = try r.cli(["result", id, "--wait", "15", "--json"], exit: 4)
        // The place frees when the running seat is stopped; the waiter must not take it.
        usleep(2_000_000)
        #expect(r.observations(nil, "blind").count == 1)
    }
}
