import Foundation
import Testing

/// U25 review round 2, findings 2, 3 and 6 (docs/U25-SPEC.md section 3).
@Suite(.serialized)
struct U25R2PreflightAcceptanceTests {
    // Finding 2: the named failure wins whatever the exit status; only the expected reply is ok; never cached as ok.
    @Test(arguments: [
        ("503 Service Unavailable", "unreachable", 0),
        ("database is locked", "busy", 0),
        ("unknown model harbor-model", "model_unavailable", 0),
        ("You've hit your usage limit, try again at Oct 9", "usage_limit", 0),
        ("Sure, here you go", "error", 0),
        ("OK, done", "error", 0),
        ("Okay", "error", 0),
        ("ok.", "ok", 1),
        ("OK!", "ok", 1),
        ("Ok", "ok", 1),
    ])
    func exitZeroReplyIsClassifiedByWhatItSays(reply: String, reason: String, okCount: Int) throws {
        let r = try U25Rig()
        try r.mode("codex", "answer")
        try r.put("codex.probe", reply)
        let row = try r.seat(r.preflight(["a"], probe: true), "a")
        #expect(row["reason"] as? String == reason)
        #expect(try r.ledger("SELECT reason FROM preflights WHERE seat='a';") == [[reason]])
        // The standing read back without a probe is the same, so a wrong reply is never cached as ok.
        let cached = try r.seat(r.preflight(["a"]), "a")
        #expect(cached["reason"] as? String == reason)
        let availability = try #require(cached["availability"] as? [String: Any])
        #expect(availability["ok"] as? Int == okCount && availability["probes"] as? Int == 1)
    }

    // Finding 2: a reply other than OK on a stdout harness (claude) is an error as well.
    @Test func exitZeroWrongReplyOnStdoutHarnessIsErrorAndNotCachedAsOk() throws {
        let r = try U25Rig()
        try r.mode("claude", "answer")
        try r.put("claude.probe", "I am ready to help")
        #expect(try r.seat(r.preflight(["b"], probe: true), "b")["reason"] as? String == "error")
        #expect(try r.seat(r.preflight(["b"]), "b")["reason"] as? String == "error")
    }

    // Finding 3: two probes of one seat at once use directories of their own and both read their own answer.
    @Test func concurrentProbesOfOneCodexSeatDoNotShareAnAnswerFile() throws {
        let r = try U25Rig()
        try r.mode("codex", "answer")
        try r.put("codex.probe", "OK")
        try r.put("codex.probe.delay", "2")
        let shared = U25R2Shared(value: r)
        let replies = U25R2Shared(value: NSMutableArray())
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let reply = try? shared.value.request("preflight", ["seats": ["a"], "probe": true])
            objc_sync_enter(replies.value); replies.value.add(reply ?? [:]); objc_sync_exit(replies.value)
        }
        for case let reply as [String: Any] in replies.value {
            let rows = try r.rows(reply)
            #expect(try r.seat(rows, "a")["reason"] as? String == "ok")
        }
        #expect(replies.value.count == 2)
        let outputs = try r.observations("codex", "probe", suffix: "output")
        let directories = try r.observations("codex", "probe", suffix: "cwd")
        #expect(outputs.count == 2 && directories.count == 2)
        let answerFiles = try outputs.map { try r.text($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(Set(answerFiles).count == 2)
        #expect(try Set(directories.map { try r.text($0) }).count == 2)
        let root = r.home.url.appendingPathComponent("runs/preflight/a").resolvingSymlinksInPath().path
        for file in answerFiles {
            #expect(URL(fileURLWithPath: file).resolvingSymlinksInPath().path.hasPrefix(root + "/"))
        }
        // The two probes really overlapped, so the test would catch a shared file.
        let starts = try r.observations("codex", "probe", suffix: "start").map { Double(try r.text($0).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        let ends = try r.observations("codex", "probe", suffix: "end").map { Double(try r.text($0).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        #expect(starts.max() ?? 1 < ends.min() ?? 0)
        // Each probe removes its directory when it ends.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        #expect(left.isEmpty)
    }

    // Finding 6: below the memory floor, or unmeasurable, the probe is busy and nothing is recorded.
    @Test(arguments: ["100", "not-a-number"])
    func probeBelowOrWithoutMemoryReadingIsBusyAndNotRecorded(free: String) throws {
        let r = try U25Rig()
        try r.configure(raw: ["limits": u6aText(["memory_floor_mb": 500])])
        try r.restart(environment: ["AGENCIL_TEST_FREE_MEMORY_MB": free])
        let row = try r.seat(r.preflight(["a"], probe: true), "a")
        #expect(row["reason"] as? String == "busy")
        #expect(try #require(row["detail"] as? String).contains("below the memory floor"))
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "0\n")
        #expect(r.observations("codex", "probe").isEmpty)
        #expect(try r.seat(r.preflight(["a"]), "a")["reason"] as? String == "not probed")
    }

    // Finding 6, control: a reading above the floor probes as before.
    @Test func probeAboveMemoryFloorRuns() throws {
        let r = try U25Rig()
        try r.configure(raw: ["limits": u6aText(["memory_floor_mb": 50])])
        try r.restart(environment: ["AGENCIL_TEST_FREE_MEMORY_MB": "100"])
        #expect(try r.seat(r.preflight(["a"], probe: true), "a")["reason"] as? String == "ok")
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "1\n")
    }
}
