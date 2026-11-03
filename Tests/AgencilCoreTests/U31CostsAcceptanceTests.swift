@testable import AgencilCore
import Foundation
import Testing

private func u31Calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 7_200)!
    return calendar
}
private func u31Date(_ day: String) -> Date {
    let parts = day.split(separator: "-").map { Int($0)! }
    return u31Calendar().date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
}
private func u31Row(_ day: String, _ name: String, _ cost: Decimal, calls: Int = 1,
                    unpriced: Int = 0) -> CostRow {
    CostRow(day: day, project: name, council: name, seat: name, model: name, caller: name,
            calls: calls, unpriced: unpriced, cost: cost)
}

@Suite(.serialized) struct U31CostsAcceptanceTests {
    // A1: the injected local day differs from UTC at now.
    @Test func thirtyCalendarDaysIncludeZerosAndAddAllAccounting() throws {
        let now = ISO8601DateFormatter().date(from: "2030-03-14T23:30:00Z")!
        let report = CostReport(rows: [u31Row("2030-03-15", "harbor", 2, calls: 2),
            u31Row("2030-03-15", "lumen", 0, calls: 3, unpriced: 3),
            u31Row("2030-02-13", "old", 99)], now: now, calendar: u31Calendar())
        let days = report.days(last: 30)
        #expect(days.count == 30)
        #expect(Set(days.map(\.date)) == Set((0..<30).map {
            u31Calendar().date(byAdding: .day, value: -$0, to: u31Date("2030-03-15"))!
        }))
        let today = try #require(days.first { $0.date == u31Date("2030-03-15") })
        #expect(today.cost == 2 && today.calls == 5 && today.unpriced == 3)
        #expect(days.filter { $0.date != today.date }.allSatisfy { $0.cost == 0 && $0.calls == 0 && $0.unpriced == 0 })
    }

    // A2: ties exercise both calls and name; both endpoints carry data.
    @Test func everyGroupUsesHalfOpenWindowAndCostCallsNameOrdering() {
        let rows = [u31Row("2030-03-01", "z", 4), u31Row("2030-03-02", "b", 2, calls: 2),
            u31Row("2030-03-03", "a", 2, calls: 2, unpriced: 1), u31Row("2030-03-04", "c", 2),
            u31Row("2030-02-28", "before", 50), u31Row("2030-03-05", "after", 50)]
        let report = CostReport(rows: rows, now: u31Date("2030-03-15"), calendar: u31Calendar())
        for group in CostGroup.allCases {
            let result = report.rows(by: group, from: u31Date("2030-03-01"), to: u31Date("2030-03-05"))
            #expect(result.map(\.name) == ["z", "a", "b", "c"])
            #expect(result.map(\.calls) == [1, 2, 2, 1])
            #expect(result.reduce(Decimal.zero) { $0 + $1.cost } == 10)
            #expect(result.reduce(0) { $0 + $1.unpriced } == 1)
        }
    }

    // A3: repeated projects aggregate within, but never across, months.
    @Test func monthsAreNewestFirstAndProjectsReconcile() {
        let report = CostReport(rows: [u31Row("2029-12-31", "harbor", 8),
            u31Row("2030-01-01", "harbor", 2), u31Row("2030-01-02", "harbor", 3),
            u31Row("2030-01-31", "lumen", 0, unpriced: 1)],
            now: u31Date("2030-03-15"), calendar: u31Calendar())
        let months = report.months()
        #expect(months.map(\.month) == ["2030-01", "2029-12"])
        #expect(months.map(\.total) == [5, 8])
        #expect(months.map(\.unpriced) == [1, 0])
        #expect(months.first?.projects.first { $0.name == "harbor" }?.cost == 5)
        for month in months {
            #expect(month.total == month.projects.reduce(Decimal.zero) { $0 + $1.cost })
        }
    }

    // A4, A5, A7: real broker and schema, seeded accounting, no mocked ledger.
    @Test func ledgerCountsExchangesResolvesOriginsAndSurvivesPruning() throws {
        let f = try U31Ledger()
        try f.seed()
        let before = try f.snapshot()
        let json = try f.costs()
        let rows = try #require(json["rows"] as? [[String: Any]])
        #expect(rows.count == 5)
        for row in rows { #expect(row["cost"] is NSNumber) }
        let report = try CostReport(json: json)
        let groups = report.months()
        #expect(groups.reduce(Decimal.zero) { $0 + $1.total } == 7)
        #expect(rows.reduce(0) { $0 + ($1["calls"] as? Int ?? 0) } == 6)
        #expect(rows.reduce(0) { $0 + ($1["unpriced"] as? Int ?? 0) } == 1)
        for (seat, project, council, model, caller, calls) in [
            ("a", "harbor/checkout", "direct", "harbor-model", "maya", 2),
            ("b", "unknown", "direct", "unknown", "jonas", 1),
            ("c", "harbor/checkout", "panel", "harbor-model", "lee", 1),
            ("d", "lumen/api", "panel", "harbor-model", "lee", 1),
            ("e", "lumen/api", "panel", "harbor-model", "owner", 1)] {
            let row = try #require(rows.first { $0["seat"] as? String == seat })
            #expect(row["project"] as? String == project && row["council"] as? String == council)
            #expect(row["model"] as? String == model && row["caller"] as? String == caller)
            #expect(row["calls"] as? Int == calls)
        }
        #expect(try f.snapshot() == before, "The read-only op changes no ledger record")
        try f.mutate("UPDATE exchanges SET question='',answer=NULL;")
        let pruned = try f.costs()
        #expect(try u6aText(rows) == u6aText(#require(pruned["rows"] as? [[String: Any]])))
    }

    // A6: independently expected latest 200, not merely a count.
    @Test func dayEntriesAreOrderedCappedOptionalAndStrictlyValidated() throws {
        let f = try U31Ledger()
        try f.seed()
        let initial = try f.costs(f.localDay("2030-03-15T10:00:00Z"))
        let followup = try #require(CostReport.entries(json: initial).first { $0.thread == "th_followup" })
        #expect(followup.sitting != nil && followup.council == "panel" && followup.project == "lumen/api")
        #expect(followup.seat == "e" && followup.model == "harbor-model" && followup.caller == "owner")
        for seq in 10...214 {
            try f.mutate("INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at,cost_usd,tokens_in,tokens_out,model) VALUES('th_direct',?,'q','a','answered',?,0.25,8,4,'harbor-model');",
                [String(seq), String(format: "2030-03-15T12:%02d:%02dZ", seq / 60, seq % 60)])
        }
        let day = f.localDay("2030-03-15T12:00:00Z")
        let json = try f.costs(day)
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.count == 200)
        let expected = (15...214).reversed().map { String(format: "2030-03-15T12:%02d:%02dZ", $0 / 60, $0 % 60) }
        #expect(entries.compactMap { $0["at"] as? String } == expected)
        let entry = try #require(CostReport.entries(json: json).first)
        #expect(entry.thread == "th_direct" && entry.sitting == nil)
        #expect(entry.tokensIn == 8 && entry.tokensOut == 4 && entry.cost == Decimal(string: "0.25"))
        let unpriced = try f.costs(f.localDay("2030-03-14T12:00:00Z"))
        let free = try #require((unpriced["entries"] as? [[String: Any]])?.first)
        #expect(free["cost"] == nil)
        #expect(CostReport.entries(json: unpriced).first?.cost == nil)
        #expect(CostReport.entries(json: try f.costs("1990-01-01")).isEmpty)
        for bad in ["2030-02-30", "2030-3-15", "no-day", "2030-03-15T00:00:00Z"] {
            let reply = try f.r.home.request(["op": "costs", "day": bad])
            #expect(reply["ok"] as? Bool == false && reply["exit"] as? Int == 64)
        }
    }
}

private final class U31Ledger {
    let r: U7aRig
    init() throws { r = try U7aRig() }
    func mutate(_ sql: String, _ bindings: [String] = []) throws {
        let ledger = try Ledger(directory: r.home.url)
        try ledger.locked { try ledger.run(sql, bindings) }
    }
    func snapshot() throws -> String {
        try r.sql("SELECT quote(thread_id),seq,quote(question),quote(answer),state,created_at,cost_usd FROM exchanges ORDER BY thread_id,seq;")
    }
    func costs(_ day: String? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["op": "costs"]
        if let day { request["day"] = day }
        return try r.base.data(r.home.request(request))
    }
    func localDay(_ timestamp: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: ISO8601DateFormatter().date(from: timestamp)!)
    }
    func seed() throws {
        try r.configure(u7aCouncil(["seats": ["a"], "synthesizer": "d"]))
        let sitting = try #require(r.decided("PASS")["sitting"] as? String)
        // Keep the real sitting, its run, and repeated seat_runs accounting.
        try mutate("DELETE FROM thread_rounds;")
        try mutate("DELETE FROM capabilities;")
        try mutate("DELETE FROM exchanges;")
        try mutate("UPDATE seat_runs SET cost_usd=999;")
        try mutate("INSERT OR REPLACE INTO run_origins(run_id,project) VALUES(?,'lumen/api');", [sitting])
        let fixtures = [("th_direct", "a", "maya", "answered", "2", "harbor-model", ""),
            ("th_unknown", "b", "jonas", "answered", "NULL", "NULL", ""),
            ("th_round", "c", "lee", "answered", "1", "harbor-model", "blind"),
            ("th_summary", "d", "lee", "answered", "1", "harbor-model", "synthesis"),
            ("th_followup", "e", "owner", "answered", "1", "harbor-model", "followup"),
            ("th_failed", "f", "maya", "failed", "100", "harbor-model", ""),
            ("th_asking", "g", "maya", "asking", "100", "harbor-model", "")]
        for (id, seat, caller, state, cost, model, round) in fixtures {
            try mutate("INSERT INTO threads(id,requested,seat,caller,created_at) VALUES(?,?,?,?,?);",
                [id, seat, seat, caller, "2030-03-15T10:00:00Z"])
            let at = id == "th_unknown" ? "2030-03-14T12:00:00Z" : "2030-03-15T10:00:00Z"
            try mutate("INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at,cost_usd,model) VALUES(?,1,'q','a',?,?,CAST(NULLIF(?,'NULL') AS REAL),NULLIF(?,'NULL'));",
                [id, state, at, cost, model])
            if !round.isEmpty {
                try mutate("INSERT INTO thread_rounds(thread_id,sitting_id,round) VALUES(?,?,?);", [id, sitting, round])
            }
        }
        try mutate("INSERT INTO runs(id,kind,status,started_at) VALUES('th_direct','thread','done','2030-03-15T10:00:00Z');")
        try mutate("INSERT INTO run_origins(run_id,project) VALUES('th_direct','harbor/checkout');")
        try mutate("INSERT INTO runs(id,kind,status,started_at) VALUES('th_round','thread','done','2030-03-15T10:00:00Z');")
        try mutate("INSERT INTO run_origins(run_id,project) VALUES('th_round','harbor/checkout');")
        try mutate("INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at,cost_usd,model) VALUES('th_direct',2,'q','a','answered','2030-03-15T11:00:00Z',2,'harbor-model');")
    }
}
