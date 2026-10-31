import Foundation
import Testing

@Suite(.serialized) struct U6dAdmissionAcceptanceTests {
    @Test func invalidHostedResidencyAndRequiresFailEveryAskWithoutRunning() throws {
        let r = try U6dRig()
        let cases: [(String, [[String: Any]], [String: Any])] = [
            ("seats", [u6aSeat(extra: ["hosted": "false"])], u6aRoute()),
            ("routes", [u6aSeat()], u6dRoute(["residency": "remote"])),
            ("routes", [u6aSeat()], u6dRoute(["requires": ["unknown"]])),
            ("routes", [u6aSeat()], u6dRoute(["requires": "read_only_files"]))]
        for (key, seats, route) in cases {
            try r.configure(seats, route: route)
            for _ in 0..<2 {
                let reply = try r.ask(repo: false)
                #expect(reply["ok"] as? Bool == false)
                #expect(reply["exit"] as? Int == 4)
                #expect((reply["error"] as? String)?.hasPrefix("failed: config \(key) is invalid: ") == true)
            }
            r.base.noAnswerSpawned()
        }
        #expect(try r.budget.sql("SELECT count(*) FROM runs;") == "0\n")
    }
    @Test func hostedDefaultsAndOverridesControlLocalResidencyBeforeReservation() throws {
        let http = try U6cHTTP(); defer { http.stop() }
        let r = try U6dRig()
        let route = u6dRoute(["residency": "local"])
        try r.configure(route: route)
        r.base.refused(try r.ask(repo: false), "refused: residency (primary is hosted)", exit: 3)
        try r.noRun()
        try r.configure([http.seat()], route: route)
        _ = try r.base.answered(r.ask(repo: false))
        #expect(http.requests().count == 1)
        try r.configure([http.seat().merging(["hosted": true]) { _, b in b }], route: route)
        r.base.refused(try r.ask(repo: false), "refused: residency (primary is hosted)", exit: 3)
        #expect(http.requests().count == 1)
        try r.configure([u6aSeat(extra: ["hosted": false])], route: route)
        _ = try r.base.answered(r.ask(repo: false))
    }
    @Test func unusablePrimaryCannotEscapeResidencyThroughHostedFallbackAndKeepsOriginalFailure() throws {
        let r = try U6dRig(mode: "codex-out")
        try r.configure([u6aSeat(), u6aSeat("backup", "claude")],
                        route: u6dRoute(["residency": "local"], fallbacks: ["backup"]))
        r.base.refused(try r.ask(repo: false), "failed: codex not signed in")
        r.base.noAnswerSpawned()
        #expect(try r.budget.sql("SELECT count(*) FROM runs;") == "0\n")
    }
    @Test func localFallbackAfterResolutionRecordsOriginalSignInFailure() throws {
        let http = try U6cHTTP(); defer { http.stop() }
        let r = try U6dRig(mode: "codex-out")
        try r.configure([u6aSeat(), http.seat("backup")],
                        route: u6dRoute(["residency": "local"], fallbacks: ["backup"]))
        let data = try r.base.answered(r.ask(repo: false), seat: "backup")
        #expect(data["substituted"] as? String == "answered by backup, fallback for primary: codex not signed in")
    }
    @Test func residencyRefusedPrimaryFallsToLocalCandidateWithExactReason() throws {
        let http = try U6cHTTP(); defer { http.stop() }
        let r = try U6dRig()
        try r.configure([u6aSeat(), http.seat("backup")],
                        route: u6dRoute(["residency": "local"], fallbacks: ["backup"]))
        let data = try r.base.answered(r.ask(repo: false), seat: "backup")
        #expect(data["substituted"] as? String == "answered by backup, fallback for primary: residency (primary is hosted)")
        r.base.noAnswerSpawned()
    }
    @Test func hermesRepoRefusesMissingPoliciesWithoutRunning() throws {
        let r = try U6dRig(); try r.repository()
        try r.configure([u6aSeat("primary", "hermes")])
        r.base.refused(try r.ask(), "refused: hermes cannot enforce no_network_tools, read_only_files", exit: 3)
        try r.noRun()
    }
    @Test func codexAndClaudeEnforceHostedRepoPolicies() throws {
        for kind in ["codex", "claude"] {
            let r = try U6dRig(); try r.repository()
            try r.configure([u6aSeat("primary", kind)])
            _ = try r.base.answered(r.ask())
        }
    }
    @Test func noFurtherMCPRefusesOpenCodeAndFallsThroughRefusedCandidatesToCodex() throws {
        let r = try U6dRig()
        let route = u6dRoute(["requires": ["no_further_mcp"]])
        try r.configure([u6aSeat("primary", "opencode")], route: route)
        r.base.refused(try r.ask(repo: false), "refused: opencode cannot enforce no_further_mcp", exit: 3)
        try r.noRun()
        try r.configure([u6aSeat("primary", "opencode"), u6aSeat("bad", "hermes"), u6aSeat("backup")],
                        route: u6dRoute(["requires": ["no_further_mcp"]], fallbacks: ["bad", "backup"]))
        let data = try r.base.answered(r.ask(repo: false), seat: "backup")
        #expect(data["substituted"] as? String == "answered by backup, fallback for primary: opencode cannot enforce no_further_mcp")
    }
    @Test func invalidRepoAbsoluteAndRelativePathsFailAndOllamaCannotReadRepo() throws {
        let http = try U6cHTTP(); defer { http.stop() }
        let r = try U6dRig()
        for path in [r.home.url.path, "relative/repository"] {
            r.base.refused(try r.base.ask(extra: ["repo": path]), "failed: repo \(path) is not a git repository")
        }
        try r.repository(); try r.configure([http.seat()])
        r.base.refused(try r.ask(), "failed: ollama seats cannot read a repo")
        r.base.noAnswerSpawned(); #expect(http.requests().isEmpty)
    }
}
