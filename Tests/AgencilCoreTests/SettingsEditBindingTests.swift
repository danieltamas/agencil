import AgencilCore
import Foundation
import Testing

/// An Edit sheet is bound to what it opened with: the editor refuses a file that changed since, and a rename or
/// delete is refused while a route caller or a route-scoped budget still names the seat or council.
@Suite struct SettingsEditBindingTests {
    /// Seats a, b, x; council panel (seat a); a route from caller x to a with every optional key set; a route budget on b.
    private func rig() throws -> U9Rig {
        let rig = try U9Rig()
        _ = try rig.store.update {
            $0["seats"] = try! u6aText(["a", "b", "x"].map { u6aSeat($0) })
            $0["aliases"] = "{}"
            $0["councils"] = "[{\"name\":\"panel\",\"seats\":[\"a\"]}]"
            $0["routes"] = try! u6aText([["callers": ["x"], "target": "a", "hop_limit": 2, "fallbacks": ["b"],
                                          "residency": "local", "requires": ["read_only_files"]] as [String: Any]])
            $0["budgets"] = "[]"
            $0["triggers"] = "[]"
        }
        return rig
    }

    private func refused(_ rig: U9Rig, _ body: () throws -> Void) throws -> SheetProblems? {
        let before = try rig.bytes()
        var caught: SheetProblems?
        do { try body(); Issue.record("the change was accepted") } catch let error as SheetProblems { caught = error }
        #expect(try rig.bytes() == before)
        return caught
    }

    // MARK: 2. seats and councils refuse a changed object

    @Test func seatUpdateRefusesWhenTheStoredSeatDiffersFromWas() throws {
        let rig = try rig()
        let was = try #require(rig.editor.current().seats.first { $0.name == "b" })
        _ = try rig.store.update {
            var seats = try! JSONSerialization.jsonObject(with: Data($0["seats"]!.utf8)) as! [[String: Any]]
            for index in seats.indices where seats[index]["name"] as? String == "b" { seats[index]["model"] = "changed-elsewhere" }
            $0["seats"] = try! u6aText(seats)
        }
        let problem = try refused(rig) { try rig.editor.update(seat: "b", was: was, with: { var draft = was; draft.model = "mine"; return draft }()) }
        #expect(problem?.fields["form"] != nil)
    }

    @Test func seatUpdateWithAMatchingWasSucceeds() throws {
        let rig = try rig()
        let was = try #require(rig.editor.current().seats.first { $0.name == "b" })
        try rig.editor.update(seat: "b", was: was, with: { var draft = was; draft.model = "mine"; return draft }())
        #expect(try SeatConfig(values: try rig.store.read().values).seat(named: "b")?.model == "mine")
    }

    @Test func councilUpdateRefusesWhenTheStoredCouncilDiffersFromWas() throws {
        let rig = try rig()
        let was = try #require(rig.editor.current().councils.first)
        _ = try rig.store.update { $0["councils"] = "[{\"name\":\"panel\",\"seats\":[\"a\",\"b\"]}]" }
        let problem = try refused(rig) {
            try rig.editor.update(council: "panel", was: was, with: CouncilDraft(name: "panel", seats: ["a"], rule: "unanimous"))
        }
        #expect(problem?.fields["form"] != nil)
    }

    @Test func councilUpdateWithAMatchingWasSucceeds() throws {
        let rig = try rig()
        let was = try #require(rig.editor.current().councils.first)
        try rig.editor.update(council: "panel", was: was, with: CouncilDraft(name: "panel", seats: ["a", "b"], rule: "unanimous"))
        #expect(try SeatConfig(values: try rig.store.read().values).council(named: "panel")?.seats == ["a", "b"])
    }

    // MARK: 3. a route is the whole route

    @Test func currentRouteCarriesEveryKeyTheSheetHasNoFieldFor() throws {
        let rig = try rig()
        let route = try #require(rig.editor.current().routes.first)
        #expect(route.fallbacks == ["b"] && route.residency == "local" && route.requires == ["read_only_files"])
    }

    @Test func routeUpdateAndRemoveRefuseWhenAnyHiddenKeyDiffers() throws {
        let rig = try rig()
        let stored = try #require(rig.editor.current().routes.first)
        var variants: [RouteDraft] = []
        var fallbacks = stored; fallbacks.fallbacks = []
        var residency = stored; residency.residency = nil
        var requires = stored; requires.requires = []
        variants = [fallbacks, residency, requires]
        for was in variants {
            let update = try refused(rig) { try rig.editor.update(routeAt: 0, was: was, with: RouteDraft(callers: ["x"], target: "a")) }
            #expect(update?.fields["form"] != nil)
            let remove = try refused(rig) { try rig.editor.remove(routeAt: 0, was: was) }
            #expect(remove?.fields["form"] != nil)
        }
    }

    @Test func routeUpdateWithTheWholeWasKeepsTheHiddenKeys() throws {
        let rig = try rig()
        let was = try #require(rig.editor.current().routes.first)
        try rig.editor.update(routeAt: 0, was: was, with: RouteDraft(callers: ["x", "maya"], target: "a", hopLimit: 3))
        let route = try #require(SeatConfig(values: try rig.store.read().values).routes.first)
        #expect(route.callers == ["x", "maya"] && route.fallbacks == ["b"])
        #expect(try rig.store.read().values["routes"]?.contains("read_only_files") == true)
    }

    // MARK: 4. a seat that is only a route caller

    @Test func seatNamedOnlyAsARouteCallerCannotBeRenamedOrRemoved() throws {
        let rig = try rig()
        let removal = try refused(rig) { try rig.editor.remove(seat: "x") }
        #expect(removal?.fields["form"]?.contains("seat x is used by") == true)
        let rename = try refused(rig) { try rig.editor.update(seat: "x", with: SeatDraft(name: "z", harness: "codex", model: "m")) }
        #expect(rename?.fields["name"]?.contains("route x to a") == true)
        _ = try rig.store.update { $0["routes"] = "[]" }
        try rig.editor.remove(seat: "x")
        #expect(try SeatConfig(values: try rig.store.read().values).seat(named: "x") == nil)
    }

    // MARK: 5. a seat or council named only by a route-scoped budget

    @Test func seatNamedOnlyByARouteBudgetCannotBeRenamedOrRemoved() throws {
        let rig = try rig()
        _ = try rig.store.update { $0["budgets"] = try! u6aText([u6aBudgetRow("cap", key: "b")]) }
        let removal = try refused(rig) { try rig.editor.remove(seat: "b") }
        #expect(removal?.fields["form"]?.contains("seat b is used by") == true)
        let rename = try refused(rig) { try rig.editor.update(seat: "b", with: SeatDraft(name: "z", harness: "codex", model: "m")) }
        #expect(rename?.fields["name"]?.contains("budget cap") == true)
    }

    @Test func councilNamedOnlyByARouteBudgetCannotBeRenamedOrRemoved() throws {
        let rig = try rig()
        _ = try rig.store.update { $0["routes"] = "[]"; $0["budgets"] = try! u6aText([u6aBudgetRow("cap", key: "panel")]) }
        let removal = try refused(rig) { try rig.editor.remove(council: "panel") }
        #expect(removal?.fields["form"]?.contains("council panel is used by") == true)
        let rename = try refused(rig) { try rig.editor.update(council: "panel", with: CouncilDraft(name: "board", seats: ["a"], rule: "majority")) }
        #expect(rename?.fields["name"]?.contains("budget cap") == true)
        _ = try rig.store.update { $0["budgets"] = "[]" }
        try rig.editor.remove(council: "panel")
    }

    @Test func aBudgetOfAnotherScopeDoesNotBlockARemoval() throws {
        let rig = try rig()
        _ = try rig.store.update { $0["routes"] = "[]"; $0["budgets"] = try! u6aText([u6aBudgetRow("cap", scope: "vendor", key: "b")]) }
        try rig.editor.remove(seat: "b")
    }

    private func u6aBudgetRow(_ name: String, scope: String = "route", key: String) -> [String: Any] {
        ["name": name, "scope": scope, "key": key, "window": "week", "dollars": 5]
    }
}
