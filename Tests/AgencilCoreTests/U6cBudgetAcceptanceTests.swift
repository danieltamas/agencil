import Foundation
import Testing

@Suite(.serialized)
struct U6cBudgetAcceptanceTests {
    @Test func invalidBudgetLimitsAndPricesFailEveryAskBeforeExecution() throws {
        let rig = try U6cRig()
        let good = u6cBudget(tokens: 10000)
        let cases: [(String, Any)] = [
            ("budgets", [good, good]),
            ("budgets", [good.merging(["scope": "planet"]) { _, b in b }]),
            ("budgets", [["name": "empty", "scope": "route", "key": "primary", "window": "run", "hard": true]]),
            ("budgets", [good.merging(["tokens": -1]) { _, b in b }]),
            ("budgets", [good.merging(["dollars": -0.1]) { _, b in b }]),
            ("budgets", [good.merging(["window": "day"]) { _, b in b }]),
            ("limits", ["seats_at_once": 0]), ("limits", ["seats_at_once": 17]),
            ("limits", ["seats_at_once": 4, "process_cap": 3]),
            ("limits", ["memory_floor_mb": -1]),
            ("seats", [u6aSeat(extra: ["price": ["input_per_mtok": -1, "output_per_mtok": 1]])]),
            ("seats", [u6aSeat(extra: ["price": ["input_per_mtok": 1, "output_per_mtok": -1]])])
        ]
        for (key, value) in cases {
            try rig.base.config(raw: [key: u6aText(value)])
            for _ in 0..<2 {
                let reply = try rig.base.ask()
                #expect(reply["ok"] as? Bool == false)
                #expect(reply["exit"] as? Int == 4)
                let message = try #require(reply["error"] as? String)
                let prefix = "failed: config \(key) is invalid: "
                #expect(message.hasPrefix(prefix)); #expect(message.count > prefix.count)
                rig.base.noAnswerSpawned()
            }
        }
        try rig.base.config()
        _ = try rig.base.answered(rig.base.ask())
    }

    @Test func unboundedSeatsRefuseHardDollarsAllowEstimatedAndCheckTokenEstimate() throws {
        let rig = try U6cRig()
        try rig.configure(budgets: [u6cBudget(dollars: 1)])
        try rig.refusedWithoutRun("budget")
        try rig.configure(budgets: [u6cBudget(dollars: 0, hard: false)])
        _ = try rig.base.answered(rig.base.ask())
        try rig.configure(budgets: [u6cBudget("tokens-low", tokens: 4095)])
        rig.base.refused(try rig.base.ask(), "refused: budget", exit: 3)
        try rig.configure(budgets: [u6cBudget("tokens-fit", tokens: 10000)])
        let d = try rig.base.answered(rig.base.ask())
        let r = try #require(d["reserved"] as? [String: Any])
        #expect(try u6cNumber(r, "tokens") >= 4096)
        try u6cWithinLimits(rig.budgets())
    }

    @Test(arguments: [37, 4096])
    func singleCallReservesFinalPromptBytesAndExactOutputCap(cap: Int) throws {
        let server = try U6cHTTP(); defer { server.stop() }
        let rig = try U6cRig()
        try rig.configure([server.seat(cap: cap == 4096 ? nil : cap)], budgets: [u6cBudget(dollars: 1, tokens: 20000)])
        let d = try rig.base.answered(rig.base.ask(question: "caf\u{00e9} prompt"))
        let body = try #require(server.requests().first)
        #expect((body["options"] as? [String: Int])?["num_predict"] == cap)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let bytes = try messages.reduce(0) { try $0 + #require($1["content"] as? String).utf8.count }
        let r = try #require(d["reserved"] as? [String: Any])
        #expect(abs(try u6cNumber(r, "dollars") - (Double(bytes) * 2 + Double(cap) * 5) / 1e6) < 1e-12)
        #expect(try u6cNumber(r, "tokens") == Double(bytes + cap))
        #expect(try u6cNumber(r, "seconds") == 20)
        let cost = try #require(d["cost"] as? [String: Any])
        #expect(cost["basis"] as? String == "provider")
        #expect(try u6cNumber(cost, "tokens") == 10)
        #expect(abs(try u6cNumber(cost, "dollars") - 0.000029) < 1e-12)
        let b = try #require(rig.budgets().first)
        #expect(abs(try u6cNumber(b, "spent_dollars") - 0.000029) < 1e-12)
        #expect(try u6cNumber(b, "reserved_tokens") == 0)
        #expect(try u6cNumber(b, "reserved_dollars") == 0)
    }

    @Test func worstCaseOverRemainingBudgetNeverReachesProvider() throws {
        let server = try U6cHTTP(); defer { server.stop() }
        let rig = try U6cRig()
        try rig.configure([server.seat()], budgets: [u6cBudget(tokens: 1)])
        try rig.refusedWithoutRun("budget")
        #expect(server.requests().isEmpty)
    }

    @Test func previouslySpentBudgetLeavesTooLittleForNextWorstCase() throws {
        let server = try U6cHTTP(); server.usage = false; defer { server.stop() }
        let rig = try U6cRig()
        try rig.configure([server.seat()])
        let probe = try rig.base.data(rig.base.ask())
        let r = try #require(probe["reserved"] as? [String: Any])
        let tokens = Int(try u6cNumber(r, "tokens"))
        try rig.configure([server.seat()], budgets: [u6cBudget(tokens: tokens + 1)])
        _ = try rig.base.answered(rig.base.ask())
        let count = server.requests().count
        rig.base.refused(try rig.base.ask(), "refused: budget", exit: 3)
        #expect(server.requests().count == count)
        let b = try #require(rig.budgets().first)
        #expect(try u6cNumber(b, "spent_tokens") == Double(tokens))
        #expect(try u6cNumber(b, "reserved_tokens") == 0)
    }

    @Test(arguments: ["provider", "answer", "fail"])
    func processUsageReconcilesAndMissingUsageIncludingFailureKeepsFullReservation(mode: String) throws {
        let rig = try U6cRig(mode: mode)
        try rig.configure(budgets: [u6cBudget(dollars: 1, tokens: 100000, hard: false)])
        let d = try rig.base.data(rig.base.ask())
        #expect(d["state"] as? String == (mode == "fail" ? "failed" : "answered"))
        let cost = try #require(d["cost"] as? [String: Any])
        let reserved = try #require(d["reserved"] as? [String: Any])
        #expect(cost["basis"] as? String == (mode == "provider" ? "provider" : "reserved"))
        #expect(try u6cNumber(cost, "tokens") == (mode == "provider" ? 11 : u6cNumber(reserved, "tokens")))
        #expect(try u6cNumber(cost, "dollars") == (mode == "provider" ? 0.25 : u6cNumber(reserved, "dollars")))
        let b = try #require(rig.budgets().first)
        #expect(try u6cNumber(b, "spent_tokens") == u6cNumber(cost, "tokens"))
        #expect(try u6cNumber(b, "spent_dollars") == u6cNumber(cost, "dollars"))
        #expect(try u6cNumber(b, "reserved_tokens") == 0)
    }

    @Test func fallbackIsAdmittedSeparatelyAndOriginalBudgetFailureSurvivesExhaustedFallbacks() throws {
        let server = try U6cHTTP(); defer { server.stop() }
        let rig = try U6cRig()
        let seats = [u6aSeat(), server.seat("backup")]
        try rig.configure(seats, budgets: [u6cBudget(dollars: 1)], routes: [u6aRoute(fallbacks: ["backup"])])
        let d = try rig.base.answered(rig.base.ask(), seat: "backup")
        #expect(d["substituted"] as? String == "answered by backup, fallback for primary: budget")
        rig.base.noAnswerSpawned()
        try rig.configure(seats, budgets: [u6cBudget(dollars: 0)], routes: [u6aRoute(fallbacks: ["backup"])])
        rig.base.refused(try rig.base.ask(), "refused: budget", exit: 3)
        let (code, _, err) = try rig.home.cli(["ask", "primary", "question", "--wait", "10"])
        #expect(code == 3); #expect(err.contains("refused: budget"))
    }

    @Test func budgetsCLIPrintsContractEnvelopeAndAllFields() throws {
        let rig = try U6cRig()
        try rig.configure(budgets: [u6cBudget(dollars: 1, tokens: 10000)])
        let (code, out, _) = try rig.home.cli(["budgets", "--json"])
        #expect(code == 0)
        let e = try brokerJSON(Data(out.utf8)); #expect(e["ok"] as? Bool == true)
        let d = try #require(e["data"] as? [String: Any])
        let rows = try #require(d["budgets"] as? [[String: Any]])
        let b = try #require(rows.first); #expect(rows.count == 1)
        for key in ["name", "scope", "key", "window", "hard", "dollars_limit", "tokens_limit",
                    "spent_dollars", "spent_tokens", "reserved_dollars", "reserved_tokens"] { #expect(b[key] != nil) }
        #expect(b["name"] as? String == "cap"); #expect(b["scope"] as? String == "route")
        #expect(b["key"] as? String == "primary"); #expect(b["window"] as? String == "lifetime")
        #expect(b["hard"] as? Bool == true)
    }
}
