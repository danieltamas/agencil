import Foundation
import Testing

@Suite(.serialized)
struct U25PreflightAcceptanceTests {
    // Acceptance 1: cache reads are available to a non-owner and never spawn.
    @Test func freshStandingIsNotProbedForEverySeat() throws {
        let r = try U25Rig(), before = r.invocations()
        let rows = try r.preflight(caller: "maya")
        #expect(Set(rows.compactMap { $0["name"] as? String }) == ["a", "b", "c", "d"])
        #expect(rows.allSatisfy { $0["reason"] as? String == "not probed" })
        #expect(r.invocations() == before)
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "0\n")
    }

    // Acceptance 2: a caller name cannot grant owner authority to probe.
    @Test func nonOwnerCannotForceProbe() throws {
        let r = try U25Rig(), before = r.invocations()
        try r.failure(r.request("preflight", ["probe": true], caller: "maya"), exit: 3, contains: ["refused:"])
        #expect(r.invocations() == before)
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "0\n")
    }

    // Acceptance 2: a real seat child cannot force a probe by claiming owner.
    @Test func seatChildCannotForceProbe() throws {
        let r = try U25Rig()
        _ = try r.preflight(["a"], probe: true)
        try r.mode("codex", "answer")
        try r.put("codex.ask", "OK")
        try r.put("codex.ask.child-preflight")
        let reply = try r.data(r.base.ask("a"))
        #expect(reply["state"] as? String == "answered")
        #expect(try r.observation("codex", "ask", suffix: "child-exit") == "3")
        #expect(try r.observation("codex", "ask", suffix: "before-child") ==
                r.observation("codex", "ask", suffix: "after-child"))
        #expect(try r.sql("SELECT count(*) FROM preflights;") == "1\n")
    }

    // Acceptance 3: classified probe failures, timeout, success, plan and availability.
    @Test(arguments: ["usage-limit", "no-credit", "model-gone", "busy", "hang", "ok"])
    func ownerProbeClassifiesEveryRequiredMode(mode: String) throws {
        let r = try U25Rig()
        try r.configure(seats: [u6aSeat("a", extra: ["cap": ["seconds": 1, "tokens": 37]])],
                        council: u7aCouncil(["seats": ["a"]]))
        try r.mode("codex", mode)
        let row = try r.seat(r.preflight(["a"], probe: true), "a")
        let reasons = ["usage-limit": "usage_limit", "no-credit": "no_credit", "model-gone": "model_unavailable",
                       "busy": "busy", "hang": "timeout", "ok": "ok"]
        #expect(row["reason"] as? String == reasons[mode])
        #expect(row["plan"] as? String == "subscription")
        if mode == "usage-limit" { #expect(row["until"] as? String == "Oct 9") }
        let availability = try #require(row["availability"] as? [String: Any])
        #expect(availability["probes"] as? Int == 1)
        #expect(availability["ok"] as? Int == (mode == "ok" ? 1 : 0))
        #expect(try r.ledger("SELECT seat,harness,model,plan,reason FROM preflights;") ==
                [["a", "codex", "test-model", "subscription", try #require(reasons[mode])]])
    }

    // Acceptance 4: each adapter gets the exact probe, closed stdin and isolated files.
    @Test(arguments: ["codex", "claude", "opencode"])
    func probeUsesHardenedAdapterAndPreflightDirectory(kind: String) throws {
        let r = try U25Rig()
        let name = kind == "codex" ? "a" : kind == "claude" ? "b" : "d"
        let row = try r.seat(r.preflight([name], probe: true), name)
        #expect(row["reason"] as? String == "ok")
        #expect(try r.observation(kind, suffix: "prompt") == "Reply with exactly: OK")
        #expect(try r.observation(kind, suffix: "stdin") == "empty-closed\n")
        let cwd = try r.observation(kind, suffix: "cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        let root = r.home.url.appendingPathComponent("runs/preflight/" + name).resolvingSymlinksInPath().path
        let actual = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        #expect(actual == root || actual.hasPrefix(root + "/"))
        let prompt = "Reply with exactly: OK", expected: [String]
        switch kind {
        case "codex":
            let output = try r.observation(kind, suffix: "output").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(URL(fileURLWithPath: output).resolvingSymlinksInPath().path.hasPrefix(root + "/"))
            expected = ["exec", "--ignore-user-config", "--disable", "hooks", "-s", "read-only",
                        "--skip-git-repo-check", "-o", output, "-m", "harbor-model", prompt]
        case "claude":
            expected = ["-p", prompt, "--model", "harbor-model", "--setting-sources", "user",
                        "--strict-mcp-config", "--permission-mode", "plan"]
        default: expected = ["run", "--model", "harbor-model", prompt]
        }
        #expect(try r.observation(kind, suffix: "argv") == expected.joined(separator: "\n") + "\n")
    }

    // Acceptance 5: a model must occupy a whole models line before it is probed.
    @Test func opencodeRejectsAbsentModelAndProbesListedModel() throws {
        let r = try U25Rig()
        try r.put("opencode.models", "harbor-model-extra\nprefix-harbor-model\n")
        let missing = try r.seat(r.preflight(["d"], probe: true), "d")
        #expect(missing["reason"] as? String == "model_unavailable")
        #expect(missing["detail"] as? String == "not in opencode models")
        #expect(r.observations("opencode", "probe").isEmpty)
        try r.put("opencode.models", "harbor-model\n")
        #expect(try r.seat(r.preflight(["d"], probe: true), "d")["reason"] as? String == "ok")
        #expect(r.observations("opencode", "probe").count == 1)
    }

    // Acceptance 6: negative standings cache too; forced refresh and model changes invalidate it.
    @Test func cacheAvoidsProcessesUntilForcedOrConfigurationChanges() throws {
        let r = try U25Rig()
        try r.mode("codex", "usage-limit")
        _ = try r.preflight(["a"], probe: true)
        try r.mode("codex", "ok")
        let before = r.invocations()
        #expect(try r.seat(r.preflight(["a"]), "a")["reason"] as? String == "usage_limit")
        #expect(r.invocations() == before)
        let fresh = try r.seat(r.preflight(["a"], probe: true), "a")
        #expect(fresh["reason"] as? String == "ok")
        let rate = try #require(fresh["availability"] as? [String: Any])
        #expect(rate["ok"] as? Int == 1 && rate["probes"] as? Int == 2)
        #expect(r.observations("codex", "probe").count == 2)
        var seats = u25Seats(); seats[0]["model"] = "lumen-model"
        try r.configure(seats: seats)
        let after = r.invocations()
        #expect(try r.seat(r.preflight(["a"]), "a")["reason"] as? String == "not probed")
        #expect(r.invocations() == after)
        _ = try r.preflight(["a"], probe: true)
        #expect(r.observations("codex", "probe").count == 3)
        #expect(try r.sql("SELECT model FROM preflights ORDER BY rowid DESC LIMIT 1;") == "lumen-model\n")
    }

    // Acceptance 7: credential-like text is scrubbed in both reply and durable detail.
    @Test func detailRedactsCredentialBeforeReturningAndPersisting() throws {
        let r = try U25Rig(); try r.mode("codex", "secret")
        let row = try r.seat(r.preflight(["a"], probe: true), "a")
        let detail = try #require(row["detail"] as? String)
        let stored = try r.sql("SELECT detail FROM preflights WHERE seat='a';")
        for value in [detail, stored] {
            #expect(value.contains("[redacted]"))
            #expect(!value.contains("sk-abcdefghijklmnopqrstuvwx"))
            #expect(!value.contains("abcdefghijklmnopqrstuvwx"))
        }
        #expect(detail.count <= 200)
    }

    // Acceptance 12: route fallback is tried for a fresh unavailable standing.
    @Test func askUsesFirstHealthyFallbackAndFailsWithoutOne() throws {
        let r = try U25Rig(); try r.mode("codex", "usage-limit")
        try r.configure(routes: [u6aRoute("a", fallbacks: ["b", "d"])])
        _ = try r.preflight(["a", "b", "d"], probe: true)
        let d = try r.data(r.base.ask("a"))
        #expect(d["seat"] as? String == "b" && d["state"] as? String == "answered")
        let line = try #require(d["substituted"] as? String)
        #expect(line.contains("answered by b") && line.contains("preflight: usage_limit"))
        try r.configure(routes: [u6aRoute("a")])
        try r.failure(r.base.ask("a"), exit: 4, contains: ["preflight: usage_limit"])
        #expect(r.observations("codex", "ask").isEmpty)
    }

    // Acceptance 18: panel labels expose the standing and the age after a probe.
    @Test func panelShowsUnprobedUsageLimitAndModelGone() throws {
        let r = try U25Rig()
        let initial = try r.seat(r.panelSeats(), "a")
        #expect(initial["standing"] as? String == "not probed")
        try r.mode("codex", "usage-limit"); _ = try r.preflight(["a"], probe: true)
        let limited = try r.seat(r.panelSeats(), "a")
        #expect(limited["standing"] as? String == "usage limit until Oct 9")
        #expect(try #require(limited["probed_ago"] as? Double) >= 0)
        try r.mode("codex", "model-gone"); _ = try r.preflight(["a"], probe: true)
        let gone = try r.seat(r.panelSeats(), "a")
        #expect(gone["standing"] as? String == "model gone")
        #expect(gone["plan"] as? String == "subscription")
        #expect(try #require(gone["probed_ago"] as? Double) < 600)
    }

    // Acceptance 19: CLI success, failure, selection and unknown names use contractual exits.
    @Test func preflightCLIExitsAndSelectionMatchStanding() throws {
        let r = try U25Rig()
        #expect(try r.cliRows(["preflight"], exit: 4).count == 4)
        _ = try r.preflight(probe: true)
        #expect(try r.cliRows(["preflight"], exit: 0).count == 4)
        let selected = try r.cliRows(["preflight", "--seats", "a,b"], exit: 0)
        #expect(Set(selected.compactMap { $0["name"] as? String }) == ["a", "b"])
        try r.mode("codex", "usage-limit"); _ = try r.preflight(["a"], probe: true)
        _ = try r.cliRows(["preflight"], exit: 4)
        let (_, error) = try r.cli(["preflight", "--seats", "nope", "--json"], exit: 64)
        #expect(error.contains("unknown seat nope"))
    }
}
