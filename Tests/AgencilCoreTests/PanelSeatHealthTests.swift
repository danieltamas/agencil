import Foundation
import Testing

/// One health for a seat in the panel op: an installed seat whose fresh preflight names a failure is down, and
/// `seats.up` counts what the items say. `busy` says nothing about the seat itself.
@Suite(.serialized)
struct PanelSeatHealthTests {
    private func seats(_ r: U25Rig) throws -> (up: Int, items: [[String: Any]]) {
        let panel = try r.data(r.request("panel"))
        let seats = try #require(panel["seats"] as? [String: Any])
        return (try #require(seats["up"] as? Int), try #require(seats["items"] as? [[String: Any]]))
    }

    @Test func aFreshFailedPreflightTakesTheSeatDownAndTheCountAgrees() throws {
        let r = try U25Rig()
        let before = try seats(r)
        #expect(before.items.allSatisfy { $0["up"] as? Bool == true } && before.up == before.items.count)
        for (mode, reason) in [("usage-limit", "usage_limit"), ("model-gone", "model_unavailable")] {
            try r.mode("codex", mode); _ = try r.preflight(["a"], probe: true)
            let after = try seats(r)
            let a = try r.seat(after.items, "a")
            #expect(a["reason"] as? String == reason)
            #expect(a["up"] as? Bool == false)
            #expect(after.up == after.items.filter { $0["up"] as? Bool == true }.count)
            #expect(after.up == before.items.count - 1)
            #expect(try r.seat(after.items, "b")["up"] as? Bool == true)
        }
    }

    @Test func aBusyPreflightKeepsTheSeatUp() throws {
        let r = try U25Rig()
        try r.mode("codex", "busy"); _ = try r.preflight(["a"], probe: true)
        let after = try seats(r)
        let a = try r.seat(after.items, "a")
        #expect(a["reason"] as? String == "busy")
        #expect(a["up"] as? Bool == true)
        #expect(after.up == after.items.count)
    }

    @Test func aRecoveredSeatIsUpAgain() throws {
        let r = try U25Rig()
        try r.mode("codex", "usage-limit"); _ = try r.preflight(["a"], probe: true)
        #expect(try r.seat(seats(r).items, "a")["up"] as? Bool == false)
        try r.mode("codex", "ok"); _ = try r.preflight(["a"], probe: true)
        #expect(try r.seat(seats(r).items, "a")["up"] as? Bool == true)
    }
}
