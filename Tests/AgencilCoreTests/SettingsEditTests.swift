import AgencilCore
import Foundation
import Testing

/// Editing and removing seats, councils and routes (docs/U9-SPEC.md "Editing").
@Suite struct SettingsEditTests {
    /// Seats a, b, c, d; council panel (seat a, spare b, synthesizer c); alias nick -> d; route owner to panel
    /// with a fallback; a trigger on panel.
    private func rig() throws -> U9Rig {
        let rig = try U9Rig()
        _ = try rig.store.update {
            $0["seats"] = try! u6aText(["a", "b", "c", "d"].map { u6aSeat($0) })
            $0["aliases"] = "{\"nick\":\"d\"}"
            $0["councils"] = "[{\"name\":\"panel\",\"seats\":[\"a\"],\"spare\":[\"b\"],\"synthesizer\":\"c\"}]"
            $0["routes"] = "[{\"callers\":[\"owner\"],\"target\":\"panel\",\"fallbacks\":[\"b\"]}]"
            $0["triggers"] = "[{\"name\":\"nightly\",\"council\":\"panel\",\"repo\":\"/tmp/repo\",\"schedule\":\"every 1h\"}]"
        }
        return rig
    }

    @Test func removeSeatIsRefusedWhileAnythingNamesIt() throws {
        let rig = try rig()
        // Council membership alone no longer blocks a delete (see SettingsSeatRemovalTests); these still do.
        let reasons = ["a": "council panel would be left with no seat",
                       "b": "seat b is used by route owner to panel (fallback)",
                       "c": "seat c is used by council panel (synthesizer)",
                       "d": "seat d is used by alias nick"]
        for (name, reason) in reasons.sorted(by: { $0.key < $1.key }) {
            let before = try rig.bytes()
            do { try rig.editor.remove(seat: name); Issue.record("\(name) was removed") }
            catch let error as SheetProblems { #expect(error.fields["form"]?.contains(reason) == true) }
            #expect(try rig.bytes() == before)
        }
    }

    @Test func removeSeatThatOnlyHoldsASpareSlotIsAllowed() throws {
        let rig = try rig()
        _ = try rig.store.update { $0["routes"] = "[]" }
        try rig.editor.remove(seat: "b")
        let council = try #require(SeatConfig(values: try rig.store.read().values).council(named: "panel"))
        #expect(council.seats == ["a"] && council.spares.isEmpty)
    }

    @Test func removeCouncilIsRefusedByTriggerAndRoute() throws {
        let rig = try rig()
        let before = try rig.bytes()
        do { try rig.editor.remove(council: "panel"); Issue.record("panel was removed") }
        catch let error as SheetProblems {
            let message = try #require(error.fields["form"])
            #expect(message.contains("trigger nightly") && message.contains("route owner to panel"))
        }
        #expect(try rig.bytes() == before)
    }

    @Test func removeSucceedsOnceUnused() throws {
        let rig = try rig()
        _ = try rig.store.update { $0["triggers"] = "[]"; $0["routes"] = "[]" }
        try rig.editor.remove(council: "panel")
        _ = try rig.store.update { $0["aliases"] = "{}" }
        try rig.editor.remove(seat: "d")
        let config = try SeatConfig(values: try rig.store.read().values)
        #expect(config.councils.isEmpty && config.seats.map(\.name) == ["a", "b", "c"])
    }

    @Test func renameThatWouldOrphanIsRefusedAndNothingIsRewritten() throws {
        let rig = try rig()
        let before = try rig.bytes()
        do { try rig.editor.update(seat: "a", with: SeatDraft(name: "z", harness: "codex", model: "m")); Issue.record("renamed") }
        catch let error as SheetProblems { #expect(error.fields["name"]?.contains("council panel (seat)") == true) }
        do { try rig.editor.update(council: "panel", with: CouncilDraft(name: "board", seats: ["a"], rule: "majority")); Issue.record("renamed") }
        catch let error as SheetProblems { #expect(error.fields["name"]?.contains("trigger nightly") == true) }
        #expect(try rig.bytes() == before)
    }

    @Test func updateKeepsKeysTheSheetHasNoFieldFor() throws {
        let rig = try rig()
        try rig.editor.update(seat: "a", with: SeatDraft(name: "a", harness: "codex", model: "new-model", capSeconds: 90, role: "skeptic"))
        let config = try SeatConfig(values: try rig.store.read().values)
        let seat = try #require(config.seat(named: "a"))
        #expect(seat.model == "new-model" && seat.capSeconds == 90 && seat.role == "skeptic" && seat.capTokens == 37)
        #expect(try rig.store.read().values["unrelated"] == "retain this exact value")
    }

    @Test func councilUpdateWritesSpareAndSynthesizerAndRefusesOverlap() throws {
        let rig = try rig()
        try rig.editor.update(council: "panel", with: CouncilDraft(name: "panel", seats: ["a", "d"], rule: "unanimous", quorum: 2,
                                                                    spare: ["b"], synthesizer: ["c"]))
        let council = try #require(SeatConfig(values: try rig.store.read().values).council(named: "panel"))
        #expect(council.seats == ["a", "d"] && council.spares == ["b"] && council.synthesizers == ["c"] && council.quorum == 2)
        let before = try rig.bytes()
        do { try rig.editor.update(council: "panel", with: CouncilDraft(name: "panel", seats: ["a"], rule: "majority", spare: ["a"], synthesizer: ["a"])) }
        catch let error as SheetProblems { #expect(Set(error.fields.keys) == ["spare", "synthesizer"]) }
        #expect(try rig.bytes() == before)
    }

    @Test func routesAreEditedByPlaceAndRefuseAStaleSheet() throws {
        let rig = try rig()
        let was = try #require(rig.editor.current().routes.first)
        try rig.editor.update(routeAt: 0, was: was, with: RouteDraft(callers: ["owner", "maya"], target: "panel", hopLimit: 3))
        let route = try #require(SeatConfig(values: try rig.store.read().values).routes.first)
        #expect(route.callers == ["owner", "maya"] && route.hopLimit == 3 && route.fallbacks == ["b"])
        let before = try rig.bytes()
        do { try rig.editor.remove(routeAt: 0, was: was); Issue.record("stale remove ran") }
        catch let error as SheetProblems { #expect(error.fields["form"] != nil) }
        #expect(try rig.bytes() == before)
        try rig.editor.remove(routeAt: 0, was: try #require(rig.editor.current().routes.first))
        #expect(try SeatConfig(values: try rig.store.read().values).routes.isEmpty)
    }
}
