import AgencilCore
import Foundation
import Testing
@testable import Agencil

/// A down seat in the panel says why: the broker's `problem` text reaches the row, and the generic fallback is only
/// for a broker that sent none.
@Suite struct PanelSeatReasonTests {
    private func item(_ extra: [String: Any]) -> [String: Any] {
        ["name": "d", "model": "m-1", "thinking": false].merging(extra) { _, b in b }
    }

    private func read(_ items: [[String: Any]]) throws -> [PanelData.SeatItem] {
        let json: [String: Any] = [
            "configured": true,
            "seats": ["total": items.count, "up": items.filter { $0["up"] as? Bool == true }.count, "thinking": 0, "items": items],
            "threads": [], "sittings": [], "findings": [], "proposals_pending": 0,
            "week": ["spend_usd": 0], "live": 0,
        ]
        return try PanelData(json: json).seats.items
    }

    @Test func problemTextIsParsedAndAbsenceIsNil() throws {
        let items = try read([item(["up": false, "problem": "opencode is not installed"]), item(["name": "e", "up": true])])
        #expect(items[0].problem == "opencode is not installed")
        #expect(items[1].problem == nil)
    }

    @Test func aDownSeatShowsTheBrokersProblemText() throws {
        for text in ["opencode is not installed", "aider has no adapter", "codex not signed in", "seat x has no endpoint"] {
            let row = DemoPanel.SeatRow(try read([item(["up": false, "problem": text])])[0])
            #expect(row.up == false)
            #expect(row.reason == text)
        }
    }

    @Test func theFallbackIsUsedOnlyWhenNoProblemWasSent() throws {
        let row = DemoPanel.SeatRow(try read([item(["up": false])])[0])
        #expect(row.reason == "harness not installed")
    }

    @Test func aFreshFailedStandingOutranksTheProblemText() throws {
        let row = DemoPanel.SeatRow(try read([item(["up": false, "problem": "opencode is not installed",
                                                    "reason": "usage_limit", "standing": "usage limit reached"])])[0])
        #expect(row.reason == "usage limit reached")
    }

    @Test func anUpSeatHasNoReasonEvenWithAProblemField() throws {
        let row = DemoPanel.SeatRow(try read([item(["up": true, "problem": "stale text"])])[0])
        #expect(row.up && row.reason.isEmpty)
    }
}
