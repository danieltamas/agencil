import AgencilCore
import Foundation
import Testing

/// Deleting a seat takes it out of every council's seat and spare lists in one write; anything else that names the
/// seat, or a council it would leave empty or short of its quorum, refuses the delete and leaves the file untouched.
@Suite struct SettingsSeatRemovalTests {
    private func rig(councils: String, routes: String = "[]", aliases: String = "{}", budgets: String = "[]",
                     seats: [String] = ["a", "b", "c", "d", "e"]) throws -> U9Rig {
        let rig = try U9Rig()
        _ = try rig.store.update {
            $0["seats"] = try! u6aText(seats.map { u6aSeat($0) })
            $0["aliases"] = aliases
            $0["councils"] = councils
            $0["routes"] = routes
            $0["budgets"] = budgets
            $0["triggers"] = "[]"
        }
        return rig
    }

    private func refusal(_ rig: U9Rig, seat: String) throws -> String {
        let before = try rig.bytes()
        var message = ""
        do { try rig.editor.remove(seat: seat); Issue.record("seat \(seat) was removed") }
        catch let error as SheetProblems { message = error.fields["form"] ?? "" }
        #expect(try rig.bytes() == before)
        #expect(!message.isEmpty)
        return message
    }

    @Test func removalTakesTheSeatOutOfEveryCouncilThatHoldsIt() throws {
        let rig = try rig(councils: """
            [{"name":"one","seats":["a","b"]},{"name":"two","seats":["c","a"],"spare":["d"]},{"name":"three","seats":["c"]}]
            """)
        try rig.editor.remove(seat: "a")
        let config = try SeatConfig(values: try rig.store.read().values)
        #expect(config.seat(named: "a") == nil)
        #expect(config.councils.map(\.name) == ["one", "two", "three"])
        #expect(try #require(config.council(named: "one")).seats == ["b"])
        #expect(try #require(config.council(named: "two")).seats == ["c"])
        #expect(try #require(config.council(named: "two")).spares == ["d"])
        #expect(try #require(config.council(named: "three")).seats == ["c"])
    }

    @Test func removalOfASpareLeavesTheSeatsAndDropsTheEmptySpareList() throws {
        let rig = try rig(councils: """
            [{"name":"one","seats":["a","b"],"spare":["d"]},{"name":"two","seats":["a"],"spare":["d","e"]}]
            """)
        try rig.editor.remove(seat: "d")
        let config = try SeatConfig(values: try rig.store.read().values)
        let one = try #require(config.council(named: "one")), two = try #require(config.council(named: "two"))
        #expect(one.seats == ["a", "b"] && one.spares.isEmpty)
        #expect(two.seats == ["a"] && two.spares == ["e"])
        #expect(config.seats.map(\.name) == ["a", "b", "c", "e"])
    }

    @Test func removalKeepsUnrelatedKeysAndOtherCouncilFields() throws {
        let rig = try rig(councils: """
            [{"name":"one","seats":["a","b"],"rule":"unanimous","quorum":1,"deadline_seconds":15}]
            """)
        _ = try rig.store.update { $0["unrelated"] = "retain this exact value" }
        try rig.editor.remove(seat: "b")
        let values = try rig.store.read().values
        #expect(values["unrelated"] == "retain this exact value")
        let council = try #require(SeatConfig(values: values).council(named: "one"))
        #expect(council.seats == ["a"] && council.quorum == 1 && council.rule == .unanimous)
        #expect(try #require(values["councils"]).contains("deadline_seconds"))
    }

    @Test func removalIsRefusedWhenTheSeatIsASynthesizer() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a"],"synthesizer":"c"}]"#)
        #expect(try refusal(rig, seat: "c").contains("seat c is used by council one (synthesizer)"))
    }

    @Test func removalIsRefusedWhenARouteTargetsTheSeat() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a"]}]"#, routes: try u6aText([u6aRoute("b")]))
        #expect(try refusal(rig, seat: "b").contains("(target)"))
    }

    @Test func removalIsRefusedWhenARouteFallsBackToTheSeat() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a","b"]}]"#, routes: try u6aText([u6aRoute("one", fallbacks: ["b"])]))
        #expect(try refusal(rig, seat: "b").contains("(fallback)"))
    }

    @Test func removalIsRefusedWhenARouteNamesTheSeatAsCaller() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a"]}]"#, routes: try u6aText([u6aRoute("one", callers: ["e"])]))
        #expect(try refusal(rig, seat: "e").contains("(caller)"))
    }

    @Test func removalIsRefusedWhenARouteScopedBudgetIsKeyedByTheSeat() throws {
        let budget: [String: Any] = ["name": "cap", "scope": "route", "key": "e", "window": "week", "dollars": 5]
        let rig = try rig(councils: #"[{"name":"one","seats":["a"]}]"#, budgets: try u6aText([budget]))
        #expect(try refusal(rig, seat: "e").contains("budget cap"))
    }

    @Test func removalIsRefusedWhenAnAliasPointsAtTheSeat() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a"]}]"#, aliases: #"{"nick":"d"}"#)
        #expect(try refusal(rig, seat: "d").contains("alias nick"))
    }

    @Test func removalIsRefusedWhenACouncilWouldBeLeftWithNoSeat() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a","b"]},{"name":"solo","seats":["c"],"spare":["a"]}]"#)
        #expect(try refusal(rig, seat: "c").contains("council solo would be left with no seat"))
    }

    @Test func removalIsRefusedWhenTheQuorumExceedsTheRemainingSeats() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a","b","c"],"quorum":3}]"#)
        _ = try refusal(rig, seat: "c")
        // A quorum the remaining seats still meet does not block.
        _ = try rig.store.update { $0["councils"] = #"[{"name":"one","seats":["a","b","c"],"quorum":2}]"# }
        try rig.editor.remove(seat: "c")
        #expect(try #require(SeatConfig(values: try rig.store.read().values).council(named: "one")).seats == ["a", "b"])
    }

    @Test func aRefusalInALaterCouncilWritesNothingToAnEarlierOne() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a","b"]},{"name":"solo","seats":["a"]}]"#)
        _ = try refusal(rig, seat: "a")
        let config = try SeatConfig(values: try rig.store.read().values)
        #expect(config.seat(named: "a") != nil)
        #expect(try #require(config.council(named: "one")).seats == ["a", "b"])
    }

    @Test func removalOfAnUnknownSeatIsRefusedAndLeavesTheFile() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a"]}]"#)
        let before = try rig.bytes()
        #expect(throws: SheetProblems.self) { try rig.editor.remove(seat: "nobody") }
        #expect(try rig.bytes() == before)
    }

    @Test func removalIsOneWriteAndReturnsTheSnapshotItWrote() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a","b"]}]"#)
        let before = try rig.store.read()
        let written = try rig.editor.remove(seat: "b")
        #expect(written.revision == before.revision + 1)
        #expect(written == (try rig.store.read()))
    }

    @Test func councilsHoldingNamesSeatAndSpareMembershipOnly() throws {
        let rig = try rig(councils: """
            [{"name":"one","seats":["a","b"]},{"name":"two","seats":["c"],"spare":["a"]},{"name":"three","seats":["c"],"synthesizer":"d"}]
            """)
        #expect(try rig.editor.councils(holding: "a") == ["one", "two"])
        #expect(try rig.editor.councils(holding: "c") == ["two", "three"])
        #expect(try rig.editor.councils(holding: "d").isEmpty)
        #expect(try rig.editor.councils(holding: "nobody").isEmpty)
    }

    @Test func removalOfASeatInNoCouncilStillWorks() throws {
        let rig = try rig(councils: #"[{"name":"one","seats":["a"]}]"#)
        try rig.editor.remove(seat: "e")
        #expect(try SeatConfig(values: try rig.store.read().values).seats.map(\.name) == ["a", "b", "c", "d"])
    }
}
