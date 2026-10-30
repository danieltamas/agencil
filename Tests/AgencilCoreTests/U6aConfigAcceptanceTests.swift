import Foundation
import Testing

@Suite(.serialized)
struct U6aConfigAcceptanceTests {
    @Test func everyInvalidCollectionFailsClosedAndValidEditWorksWithoutRestart() throws {
        let rig = try U6aRig()
        let invalid: [(String, Any)] = [
            ("seats", [u6aSeat(), u6aSeat()]),
            ("seats", [u6aSeat("Bad_Name")]),
            ("seats", [u6aSeat("primary", "unknown")]),
            ("routes", [u6aRoute().merging(["hop_limit": 0]) { _, b in b }]),
            ("routes", [u6aRoute().merging(["hop_limit": 5]) { _, b in b }]),
            ("routes", [u6aRoute(fallbacks: ["missing"])]),
            ("aliases", ["reviewer": "missing"]),
            ("aliases", ["reviewer": "second", "second": "primary"])
        ]
        for (key, value) in invalid {
            try rig.config(raw: [key: u6aText(value)])
            let reply = try rig.ask()
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["error"] as? String)?.hasPrefix("failed: config \(key) is invalid: ") == true)
            rig.noAnswerSpawned()
        }
        for key in ["seats", "routes", "aliases"] {
            try rig.config(raw: [key: "{broken"])
            let reply = try rig.ask()
            #expect((reply["error"] as? String)?.hasPrefix("failed: config \(key) is invalid: ") == true)
            rig.noAnswerSpawned()
        }
        try rig.config()
        _ = try rig.answered(rig.ask())
    }

    @Test func noRouteCLIExitsThreeWithoutRunAndRecordsOneRefusedRequest() throws {
        let rig = try U6aRig()
        try rig.config(routes: [])
        let (code, _, error) = try rig.home.cli(["ask", "primary", "question"])
        #expect(code == 3)
        #expect(error.trimmingCharacters(in: .whitespacesAndNewlines) ==
                "agencil: refused: no route from owner to primary")
        rig.noAnswerSpawned()
        let sqlite = try BrokerProcess(["-readonly", rig.home.url.appendingPathComponent("agencil.sqlite").path,
                                       "SELECT count(*) FROM runs; SELECT count(*) FROM requests;"],
                                      home: rig.home.url, executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
        let (status, out, _) = try sqlite.finish()
        #expect(status == 0)
        #expect(out.split(whereSeparator: \.isWhitespace).map(String.init) == ["0", "1"])
        let dump = try BrokerProcess(["-readonly", rig.home.url.appendingPathComponent("agencil.sqlite").path,
                                     ".dump requests"], home: rig.home.url,
                                    executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
        let (dumpCode, rows, _) = try dump.finish()
        #expect(dumpCode == 0)
        #expect(rows.split(separator: "\n").filter { $0.hasPrefix("INSERT INTO") }.contains { $0.contains("refused") })
    }

    @Test func callerKindDoesNotAuthorizeAnotherKindButAnyDoes() throws {
        let rig = try U6aRig()
        try rig.config(routes: [u6aRoute(callers: ["codex"])])
        rig.refused(try rig.ask(caller: "claude"), "refused: no route from claude to primary", exit: 3)
        rig.noAnswerSpawned()
        _ = try rig.answered(rig.ask(caller: "codex"))
        try rig.config(routes: [u6aRoute(callers: ["any"])])
        _ = try rig.answered(rig.ask(caller: "claude"))
    }

    @Test func namedCallerRouteWinsBeforeAnyAndFirstMatchingRouteWins() throws {
        let rig = try U6aRig(["codex", "claude"], mode: "codex-out")
        try rig.config(seats: [u6aSeat(), u6aSeat("backup", "claude")], routes: [
            u6aRoute(callers: ["any"]), u6aRoute(callers: ["maya"], fallbacks: ["backup"]),
            u6aRoute(callers: ["maya"])
        ])
        _ = try rig.answered(rig.ask(caller: "maya"), seat: "backup")
    }

    @Test func aliasRouteAuthorizesAliasAndResolvedSeatAndUnknownTargetFailsAfterRoute() throws {
        let rig = try U6aRig()
        try rig.config(routes: [u6aRoute("reviewer"), u6aRoute("missing")], aliases: ["reviewer": "primary"])
        _ = try rig.answered(rig.ask("reviewer"))
        _ = try rig.answered(rig.ask("primary"))
        rig.refused(try rig.ask("missing"), "failed: no seat or alias named missing")
        let (code, _, error) = try rig.home.cli(["ask", "missing", "question"])
        #expect(code == 4)
        #expect(error.contains("failed: no seat or alias named missing"))
    }

    @Test func versionOutsidePinFailsWithDetectedVersion() throws {
        let rig = try U6aRig()
        try rig.config(seats: [u6aSeat(extra: ["pin": "1.x"])])
        rig.refused(try rig.ask(), "failed: codex 0.9.4 is outside the pin 1.x")
        rig.noAnswerSpawned()
    }

    @Test func newestOfTwoDetectedInstallsWins() throws {
        let rig = try U6aRig([])
        // PATH is a standard discovery input, not a second Agencil seam.
        let old = rig.home.url.appendingPathComponent("old")
        _ = try rig.install("codex", version: "1.2.0")
        _ = try rig.install("codex", directory: old, version: "0.9.4")
        rig.broker?.kill(); _ = try rig.broker?.finish()
        rig.broker = try rig.home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": old.path,
            "PATH": rig.bin.path + ":/usr/bin:/bin", "STUB_RECORD": rig.record.path, "STUB_MODE": "answer"])
        try rig.config(seats: [u6aSeat(extra: ["pin": "1.x"])])
        _ = try rig.answered(rig.ask())
    }

    @Test func absentHarnessFailsWithoutAnswerProcess() throws {
        let rig = try U6aRig([])
        rig.refused(try rig.ask(), "failed: codex is not installed")
        rig.noAnswerSpawned()
    }

    @Test func signedOutRequestedSeatUsesFirstUsableFallbackAndRecordsExactSubstitution() throws {
        let rig = try U6aRig(["codex", "claude", "hermes"], mode: "codex-out claude-out")
        try rig.config(seats: [u6aSeat(), u6aSeat("second", "claude"), u6aSeat("third", "hermes")],
                       routes: [u6aRoute(fallbacks: ["second", "third"])])
        let data = try rig.answered(rig.ask(), seat: "third")
        #expect(data["substituted"] as? String == "answered by third, fallback for primary: codex not signed in")
        #expect(try rig.contents(".events") == "hermes\n")
    }

    @Test func firstUsableFallbackWinsAndNoUsableFallbackKeepsOriginalFailure() throws {
        let rig = try U6aRig(["codex", "claude", "hermes"], mode: "codex-out")
        try rig.config(seats: [u6aSeat(), u6aSeat("second", "claude"), u6aSeat("third", "hermes")],
                       routes: [u6aRoute(fallbacks: ["second", "third"])])
        _ = try rig.answered(rig.ask(), seat: "second")
        try rig.config(routes: [u6aRoute(fallbacks: ["primary"])])
        rig.refused(try rig.ask(), "failed: codex not signed in")
        let (code, _, error) = try rig.home.cli(["ask", "primary", "question"])
        #expect(code == 4)
        #expect(error.contains("failed: codex not signed in"))
    }
}
