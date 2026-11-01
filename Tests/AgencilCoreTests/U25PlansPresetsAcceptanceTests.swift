import Foundation
import Testing

@Suite(.serialized)
struct U25PlansPresetsAcceptanceTests {
    // Acceptance 14: a free agentic seat fits a hard zero dollar budget.
    @Test func freeSeatIsAdmittedAndChargedZeroWhileCreditSeatIsRefused() throws {
        let r = try U25Rig()
        var seats = u25Seats(); seats[0]["plan"] = "free"
        let budgets = try u6aText([u6cBudget(key: "a", dollars: 0)])
        try r.configure(seats: seats, raw: ["budgets": budgets])
        let answered = try r.data(r.base.ask("a"))
        #expect(answered["state"] as? String == "answered")
        let reserved = try #require(answered["reserved"] as? [String: Any])
        #expect(try u6cNumber(reserved, "dollars") == 0)
        #expect(try u6cNumber(reserved, "tokens") > 0)
        let budget = try #require(r.rows(r.request("budgets"), key: "budgets").first)
        #expect(try u6cNumber(budget, "spent_dollars") == 0)
        #expect(try u6cNumber(budget, "reserved_dollars") == 0)
        #expect(try r.sql("SELECT count(*) FROM seat_runs WHERE cost_usd<>0;") == "0\n")
        seats[0]["plan"] = "credit"
        try r.configure(seats: seats, raw: ["budgets": budgets])
        let before = r.observations(nil, "ask").count
        try r.failure(r.base.ask("a"), exit: 3, contains: ["refused: budget"])
        #expect(r.observations(nil, "ask").count == before)
    }

    // Acceptance 14: a priced free seat is invalid configuration.
    @Test func freeSeatWithPriceIsRejectedWithItsName() throws {
        let r = try U25Rig()
        var seats = u25Seats()
        seats[0]["plan"] = "free"
        seats[0]["price"] = ["input_per_mtok": 1, "output_per_mtok": 2]
        try r.configure(seats: seats)
        try r.failure(r.request("preflight"), exit: 4,
                      contains: ["failed: config seats is invalid:", "seat a is free and has a price"])
        try r.noWork()
    }

    // Acceptance 15: absent plans derive from harness and the model suffix.
    @Test func plansDefaultToSubscriptionFreeCreditAndLocal() throws {
        let r = try U25Rig()
        let seats = [u6aSeat("a", "codex"),
                     u6aSeat("b", "opencode", extra: ["model": "harbor-free"]),
                     u6aSeat("c", "opencode", extra: ["model": "lumen-model"]),
                     u6aSeat("d", "ollama", extra: ["endpoint": "http://127.0.0.1:1", "hosted": false])]
        try r.configure(seats: seats)
        let rows = try r.preflight()
        for (name, plan) in [("a", "subscription"), ("b", "free"), ("c", "credit"), ("d", "local")] {
            #expect(try r.seat(rows, name)["plan"] as? String == plan)
        }
    }

    // Acceptance 15: unknown plan strings fail closed.
    @Test func unknownPlanIsAConfigError() throws {
        let r = try U25Rig()
        var seats = u25Seats(); seats[0]["plan"] = "gold"
        try r.configure(seats: seats)
        try r.failure(r.request("preflight"), exit: 4,
                      contains: ["failed: config seats is invalid:", "seat a has an unknown plan"])
        try r.noWork()
    }

    // Acceptance 17: preset listing is complete, explicit and does not mutate config.
    @Test func presetsListEveryCatalogFieldWithoutAddingSeats() throws {
        let r = try U25Rig()
        let config = r.home.url.appendingPathComponent("config.json")
        let before = try Data(contentsOf: config)
        let (out, _) = try r.cli(["seats", "presets"], exit: 0)
        let presets = [
            ["gpt-codex", "codex", "gpt-6.1-sol", "openai", "subscription"],
            ["claude-opus", "claude", "opus", "anthropic", "subscription"],
            ["nemotron-free", "opencode", "opencode/nemotron-3.5-lightning-free", "nvidia", "free"],
            ["glm-free", "opencode", "opencode/glm-5.3-flash-free", "zhipu", "free"],
            ["deepseek-free", "opencode", "opencode/deepseek-v4.1-flash-free", "deepseek", "free"],
            ["mimo-free", "opencode", "opencode/mimo-v2.6-flash-free", "xiaomi", "free"],
            ["ollama-local", "ollama", "gemma4:26b", "google", "local"]]
        for preset in presets {
            let line = try #require(out.split(separator: "\n").first { $0.contains(preset[0]) })
            for field in preset { #expect(line.contains(field)) }
        }
        for excluded in ["big-pickle", "beam-free", "flint-40b-free"] { #expect(!out.contains(excluded)) }
        #expect(try Data(contentsOf: config) == before)
    }

    // Acceptance 17: add uses config validation; duplicate and unknown presets fail.
    @Test func presetAddPersistsValidatedVendorPlanAndHostedAndRejectsDuplicates() throws {
        let r = try U25Rig()
        _ = try r.cli(["seats", "add", "--preset", "glm-free"], exit: 0)
        let config = try brokerJSON(Data(contentsOf: r.home.url.appendingPathComponent("config.json")))
        let values = try #require(config["values"] as? [String: String])
        let text = try #require(values["seats"])
        let rawSeats = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let saved = try r.seat(rawSeats, "glm-free")
        #expect(saved["harness"] as? String == "opencode")
        #expect(saved["model"] as? String == "opencode/glm-5.3-flash-free")
        #expect(saved["vendor"] as? String == "zhipu")
        #expect(saved["plan"] as? String == "free" && saved["hosted"] as? Bool == true)
        // The broker's configuration read validates the persisted seat through SeatConfig.
        #expect(try r.seat(r.preflight(["glm-free"]), "glm-free")["plan"] as? String == "free")
        let before = try Data(contentsOf: r.home.url.appendingPathComponent("config.json"))
        let (_, duplicate) = try r.cli(["seats", "add", "--preset", "glm-free"], exit: 4)
        #expect(duplicate.lowercased().contains("name"))
        let (_, unknown) = try r.cli(["seats", "add", "--preset", "nope"], exit: 64)
        #expect(unknown.contains("nope"))
        #expect(try Data(contentsOf: r.home.url.appendingPathComponent("config.json")) == before)
    }
}
