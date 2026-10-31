import AgencilCore
import Foundation
import Testing

@Suite struct U9SettingsAcceptanceTests {
    @Test func invalidSeatReportsAllFieldsWithoutWriting() throws {
        let r = try U9Rig()
        try r.refuses(["name", "harness", "model", "capSeconds"]) {
            try r.editor.add(SeatDraft(name: "BAD NAME", harness: "unknown", model: "", capSeconds: 0))
        }
    }
    @Test func invalidCouncilReportsAllFieldsWithoutWriting() throws {
        let r = try U9Rig()
        try r.refuses(["name", "seats", "rule", "quorum"]) {
            try r.editor.add(CouncilDraft(name: "", seats: [], rule: "unknown", quorum: 0))
        }
    }
    @Test func invalidRouteReportsAllFieldsWithoutWriting() throws {
        let r = try U9Rig()
        try r.refuses(["callers", "target", "hopLimit"]) {
            try r.editor.add(RouteDraft(callers: [], target: "", hopLimit: 0))
        }
    }
    @Test(arguments: ["", "BAD NAME", "a", "alias-a"])
    func seatNamesAreValidated(name: String) throws {
        let r = try U9Rig()
        try r.refuses(["name"]) { try r.editor.add(SeatDraft(name: name, harness: "codex", model: "test-model")) }
    }
    @Test(arguments: ["BAD NAME", "panel"])
    func councilNamesAreValidated(name: String) throws {
        let r = try U9Rig()
        try r.refuses(["name"]) { try r.editor.add(CouncilDraft(name: name, seats: ["a"], rule: "majority")) }
    }
    @Test(arguments: [0, 3601]) func seatCapRange(cap: Int) throws {
        let r = try U9Rig()
        try r.refuses(["capSeconds"]) { try r.editor.add(SeatDraft(name: "new", harness: "codex", model: "m", capSeconds: cap)) }
    }
    @Test(arguments: [0, 2]) func quorumRange(quorum: Int) throws {
        let r = try U9Rig()
        try r.refuses(["quorum"]) { try r.editor.add(CouncilDraft(name: "new", seats: ["a"], rule: "majority", quorum: quorum)) }
    }
    @Test func unknownCouncilSeat() throws {
        let r = try U9Rig()
        try r.refuses(["seats"]) { try r.editor.add(CouncilDraft(name: "new", seats: ["missing"], rule: "majority")) }
    }
    @Test(arguments: [0, 5]) func hopRange(hop: Int) throws {
        let r = try U9Rig()
        try r.refuses(["hopLimit"]) { try r.editor.add(RouteDraft(callers: ["owner"], target: "a", hopLimit: hop)) }
    }
    @Test func unknownRouteTarget() throws {
        let r = try U9Rig()
        try r.refuses(["target"]) { try r.editor.add(RouteDraft(callers: ["owner"], target: "missing")) }
    }
    @Test func wholeConfigFailureUsesFormAndPreservesBytes() throws {
        let r = try U9Rig()
        _ = try r.store.update { $0["limits"] = "{\"seats_at_once\":0}" }
        let values = try r.store.read().values
        var message = ""
        do { _ = try SeatConfig(values: values); Issue.record("Invalid fixture accepted") }
        catch let error as ConfigProblem { message = error.message }
        try r.refuses(["form"]) {
            do { return try r.editor.add(SeatDraft(name: "new", harness: "codex", model: "m")) }
            catch let error as SheetProblems { #expect(error.fields["form"] == message); throw error }
        }
    }
    @Test func movedRevisionIsRefusedWithoutClobberingOtherWriter() throws {
        let r = try U9Rig(), before = try r.store.read()
        let store = r.store
        let editor = ConfigEditor(directory: r.home.url, beforeUpdate: {
            _ = try store.update { $0["other-writer"] = "won" }
        })
        do { _ = try editor.set("notify", "[]"); Issue.record("Stale edit accepted") }
        catch let error as SheetProblems { #expect(error.fields["form"]?.isEmpty == false) }
        let after = try r.store.read()
        #expect(after.revision == before.revision + 1)
        #expect(after.values == before.values.merging(["other-writer": "won"]) { _, new in new })
    }
    @Test(arguments: ["notify", "look", "limits"])
    func scalarsWriteExactlyOnceAndRejectBadValues(key: String) throws {
        let r = try U9Rig(), before = try r.store.read()
        let values = ["notify": ["[]", "[\"block\"]"], "look": ["solidGlass", "solidGlassLight"],
                      "limits": ["{\"seats_at_once\":2}", "{\"seats_at_once\":3}"]]
        let pair = try #require(values[key])
        let first = try r.editor.set(key, pair[0])
        #expect(first.revision == before.revision + 1 && first.values[key] == pair[0])
        _ = try SeatConfig(values: first.values)
        let bytes = try r.bytes()
        #expect(try r.editor.set(key, pair[0]) == first)
        #expect(try r.bytes() == bytes)
        let second = try r.editor.set(key, pair[1])
        #expect(second.revision == before.revision + 2 && second.values[key] == pair[1])
        #expect(second.values["unrelated"] == before.values["unrelated"])
        let bad = key == "look" ? "unknown" : key == "notify" ? "[\"unknown\"]" : "{\"seats_at_once\":0}"
        // Scalar refusals need not be field-specific, but must carry a problem.
        let saved = try r.bytes(), snapshot = try r.store.read()
        do { _ = try r.editor.set(key, bad); Issue.record("Bad scalar accepted") }
        catch let error as SheetProblems { #expect(!error.fields.isEmpty) }
        #expect(try r.bytes() == saved && r.store.read() == snapshot)
    }
    @Test func unknownScalarIsRefused() throws {
        let r = try U9Rig(), before = try r.bytes()
        let revision = try r.store.read().revision
        do { _ = try r.editor.set("arbitrary", "on"); Issue.record("Unknown scalar accepted") }
        catch let error as SheetProblems { #expect(!error.fields.isEmpty) }
        #expect(try r.bytes() == before && r.store.read().revision == revision)
    }
    @Test func newSeatIsAskedByAlreadyRunningBroker() throws {
        let r = try U6aRig()
        let store = ConfigStore(directory: r.home.url), before = try store.read()
        let editor = ConfigEditor(directory: r.home.url)
        let seat = try editor.add(SeatDraft(name: "new", harness: "codex", model: "test-model", capSeconds: 20))
        let parsed = try SeatConfig(values: seat.values)
        #expect(parsed.seat(named: "new")?.capSeconds == 20)
        #expect(seat.revision == before.revision + 1)
        #expect(seat.values["routes"] == before.values["routes"])
        _ = try editor.add(RouteDraft(callers: ["owner"], target: "new", hopLimit: 1))
        _ = try r.answered(r.ask("new"), seat: "new")
    }
    @Test func newCouncilAndRouteAreUsedWithoutRestart() throws {
        let r = try U7aRig(), editor = ConfigEditor(directory: r.home.url)
        let before = try ConfigStore(directory: r.home.url).read()
        let council = try editor.add(CouncilDraft(name: "new-panel", seats: ["a", "b", "c"], rule: "majority", quorum: 2))
        #expect(council.revision == before.revision + 1)
        #expect(try SeatConfig(values: council.values).councils.contains { $0.name == "new-panel" })
        #expect(council.values["seats"] == before.values["seats"])
        let route = try editor.add(RouteDraft(callers: ["owner"], target: "new-panel", hopLimit: 4))
        #expect(route.revision == council.revision + 1)
        #expect(try SeatConfig(values: route.values).route(from: "owner", to: "new-panel")?.hopLimit == 4)
        try r.put("brief", "change_kind: design\nquestion: inspect packet\nauthor_vendor: google\n")
        let reply = try r.cli(["wake", "new-panel", "--brief", r.control.appendingPathComponent("brief").path, "--wait", "15"], exit: 0)
        #expect(try r.verdict(reply)["verdict"] as? String == "PASS")
        #expect(!r.observations().isEmpty)
    }
    @Test func validRangeEdgesAndAliasTarget() throws {
        let r = try U9Rig()
        for (index, cap) in [1, 3600].enumerated() {
            _ = try r.editor.add(SeatDraft(name: "edge-\(index)", harness: "codex", model: "m", capSeconds: cap))
        }
        for (index, quorum) in [1, 2].enumerated() {
            _ = try r.editor.add(CouncilDraft(name: "council-edge-\(index)", seats: ["a", "edge-0"], rule: "majority", quorum: quorum))
        }
        for hop in [1, 4] { _ = try r.editor.add(RouteDraft(callers: ["owner-\(hop)"], target: "alias-a", hopLimit: hop)) }
        _ = try SeatConfig(values: r.store.read().values)
    }
    @Test(arguments: ["codex", "opencode"])
    func accessReadsActualEntryAndUninstallRestoresBytes(harness: String) throws {
        let f = try U9AccessFixture(harness)
        #expect(try !f.access.state(harness).installed)
        try f.assertEntry(f.access.install(harness), harness: harness)
        try f.assertEntry(f.access.state(harness), harness: harness)
        // Mutate only unrelated text: fresh state must still describe the on-disk entry.
        let installed = try f.bytes()
        let changed = String(decoding: installed, as: UTF8.self).replacingOccurrences(of: "--caller", with: "--fresh-read")
        #expect(changed != String(decoding: installed, as: UTF8.self))
        try Data(changed.utf8).write(to: f.file)
        #expect(try f.access.state(harness).entry?.contains("--fresh-read") == true)
        try installed.write(to: f.file)
        let removed = try f.access.uninstall(harness)
        #expect(!removed.installed && removed.entry == nil && removed.problem == nil)
        #expect(try f.bytes() == f.original)
        #expect(try !f.access.state(harness).installed)
    }
    @Test(arguments: ["codex", "opencode"])
    func malformedHarnessFileIsReportedAndUntouched(harness: String) throws {
        let f = try U9AccessFixture(harness)
        let malformed = Data((harness == "codex" ? "[broken\n" : "{broken").utf8)
        try malformed.write(to: f.file)
        let state = try f.access.state(harness)
        #expect(!state.installed && state.entry == nil)
        #expect(state.problem?.contains(f.file.path) == true)
        do { _ = try f.access.install(harness); Issue.record("Malformed config accepted") }
        catch let error as AccessError { #expect(!error.message.isEmpty) }
        #expect(try f.bytes() == malformed)
    }
    @Test func unsupportedHarnessThrowsAccessError() throws {
        let f = try U9AccessFixture("codex")
        for operation in [f.access.state, f.access.install, f.access.uninstall] {
            do { _ = try operation("unsupported"); Issue.record("Unsupported harness accepted") }
            catch let error as AccessError { #expect(!error.message.isEmpty) }
        }
        #expect(try f.bytes() == f.original)
    }
}
