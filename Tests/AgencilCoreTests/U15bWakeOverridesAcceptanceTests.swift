import Foundation
import Testing
import AgencilCore

@Suite(.serialized) struct U15bWakeOverridesAcceptanceTests {
    private func wake(_ r: U7aRig, _ extra: [String: Any] = [:]) throws -> [String: Any] {
        try r.home.request(["op": "wake", "caller": "owner", "council": "panel",
            "change_kind": "design", "question": "Inspect overrides", "author_vendor": "google",
            "wait_seconds": 15].merging(extra) { _, value in value })
    }

    private func verdict(_ r: U7aRig, _ extra: [String: Any] = [:]) throws -> [String: Any] {
        try r.verdict(r.base.data(wake(r, extra)))
    }

    private func unopened(_ r: U7aRig) throws {
        try r.noRuns()
        #expect(try r.sql("SELECT count(*) FROM sittings;") == "0\n")
        #expect(try r.sql("SELECT count(*) FROM launches;") == "0\n")
        #expect(try r.sql("SELECT count(*) FROM briefs;") == "0\n")
    }

    @Test func subsetRunsExactlyRequestedSeatsInCouncilOrderAndRecordsOverrides() throws {
        let r = try U7aRig()
        let v = try verdict(r, ["seats": ["c", "a"], "cap_seconds": 5])
        #expect(v["verdict"] as? String == "PASS")
        #expect(try r.rows(v, "votes").compactMap { $0["seat"] as? String } == ["a", "c"])
        #expect(r.observations("a", "blind").count == 1)
        #expect(r.observations("c", "blind").count == 1)
        #expect(r.observations().count == 2)
        #expect(r.observations("b").isEmpty)
        #expect(r.observations("d").isEmpty)
        let lines = try r.sql("SELECT body FROM briefs;").split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("seats:") && $0.contains("a") && $0.contains("c") })
        #expect(lines.contains("cap: 5"))
    }

    @Test(arguments: [["d"], ["absent"], ["a", "a"], [String]()])
    func invalidSeatSelectionOpensNothing(_ seats: [String]) throws {
        let r = try U7aRig()
        r.base.refused(try wake(r, ["seats": seats]),
            "usage: seats must be seats of the council", exit: 64)
        try unopened(r)
    }

    @Test func reducedPanelCannotMeetOriginalQuorum() throws {
        let r = try U7aRig()
        try r.configure(u7aCouncil(["quorum": 3]))
        let v = try verdict(r, ["seats": ["a", "c"]])
        #expect(v["verdict"] as? String == "INCOMPLETE")
        #expect(try r.rows(v, "votes").compactMap { $0["seat"] as? String } == ["a", "c"])
        #expect(r.observations("b").isEmpty)
    }

    @Test func stubObservesLaunchCapsAndShorterConfiguredCapSurvives() throws {
        let r = try U7aRig()
        var seats = u7aSeats()
        seats[0]["cap"] = ["seconds": 3, "tokens": 37]
        try r.configure(seats: seats)
        // No cap is passed as an argv or environment value. AGENCIL_RUN identifies
        // the broker launch whose reservation sets TrackedRun's absolute deadline.
        // Read that reservation inside the stub, before it answers, rather than
        // inferring a timeout from wall-clock scheduling or a budget quote.
        let original = try String(contentsOf: brokerFixture("u7a-seat.sh"), encoding: .utf8)
        let marker = "record=$STUB_DIR/record.$n.$key"
        #expect(original.contains(marker))
        let instrumented = original.replacingOccurrences(of: marker, with: marker + "\n" +
            "/usr/bin/sqlite3 -readonly \"$STUB_LEDGER\" \"SELECT reserved_seconds FROM launches WHERE id='$AGENCIL_RUN';\" > \"$record.cap\"")
        for kind in ["codex", "claude", "hermes", "opencode"] {
            try Data(instrumented.utf8).write(to: r.base.bin.appendingPathComponent(kind))
        }
        let v = try verdict(r, ["cap_seconds": 5])
        #expect(v["verdict"] as? String == "PASS")
        for (seat, expected) in [("a", 3), ("b", 5), ("c", 5)] {
            let records = r.observations(seat, "blind", suffix: "cap")
            #expect(records.count == 1)
            let observed = try r.text(#require(records.first)).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(Int(observed) == expected)
        }
    }

    @Test(arguments: [0.0, 86401.0, 2.5, -1.0])
    func invalidCapsOpenNothing(_ cap: Double) throws {
        let r = try U7aRig()
        r.base.refused(try wake(r, ["cap_seconds": cap]),
            "usage: cap must be a whole number of seconds", exit: 64)
        try unopened(r)
    }

    @Test(arguments: [1, 86400])
    func inclusiveCapBoundsAreAccepted(_ cap: Int) throws {
        let r = try U7aRig()
        let v = try verdict(r, ["cap_seconds": cap])
        #expect(v["verdict"] as? String == "PASS")
        #expect(r.observations().count == 3)
    }

    @Test func omittedOverridesKeepFullPanelAndConfiguredCaps() throws {
        let r = try U7aRig()
        let v = try verdict(r)
        #expect(v["verdict"] as? String == "PASS")
        #expect(try r.rows(v, "votes").compactMap { $0["seat"] as? String } == ["a", "b", "c"])
        #expect(r.observations().count == 3)
        #expect(try r.sql("SELECT reserved_seconds FROM launches ORDER BY id;") == "10\n10\n10\n")
    }

    @Test func cliForwardsBothOverrides() throws {
        let r = try U7aRig()
        let v = try r.decided("PASS", extra: ["--seats", "c,a", "--cap", "5"])
        #expect(try r.rows(v, "votes").compactMap { $0["seat"] as? String } == ["a", "c"])
        #expect(r.observations().count == 2)
        #expect(try r.sql("SELECT reserved_seconds FROM launches ORDER BY id;") == "5\n5\n")
    }

    @Test(arguments: [["--cap", "nope"], ["--cap", "2.5"], ["--seats", ""],
                      ["--seats", "a,a"], ["--seats", "d"], ["--cap"], ["--seats"]])
    func cliRejectsInvalidValuedFlags(_ flags: [String]) throws {
        let r = try U7aRig()
        try r.put("brief", "change_kind: design\nquestion: Inspect overrides\nauthor_vendor: google\n")
        let (code, _, _) = try r.home.cli(["wake", "panel", "--brief",
            r.control.appendingPathComponent("brief").path] + flags)
        #expect(code == 64)
        try unopened(r)
    }
}
