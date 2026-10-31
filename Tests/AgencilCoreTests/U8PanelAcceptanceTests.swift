import AgencilCore
import Foundation
import Testing

@Suite(.serialized) struct U8PanelAcceptanceTests {
    @Test func freshHomeHasCompleteEmptySnapshotAndPanelCLI() throws {
        let home = try BrokerHome()
        let broker = try home.serve(); defer { broker.kill() }
        let reply = try home.request(["op": "panel"])
        #expect(reply["ok"] as? Bool == true)
        let json = try #require(reply["data"] as? [String: Any])
        let data = try PanelData(json: json)
        #expect(!data.configured)
        #expect(data.threads.isEmpty && data.sittings.isEmpty && data.findings.isEmpty)
        #expect(data.seats.total == 0 && data.seats.up == 0 && data.seats.thinking == 0)
        #expect(data.seats.items.isEmpty && data.live == 0 && data.proposalsPending == 0)
        #expect(data.week.spendUSD == 0 && data.week.budgetUSD == nil)
        let (code, output, _) = try home.cli(["panel", "--json"])
        #expect(code == 0)
        #expect(try brokerJSON(Data(output.utf8))["ok"] as? Bool == true)
    }

    @Test func configuredRowsOwnerDispositionsCostsAndReadOnlyOperation() throws {
        let r = try U8Rig(); try r.seed(4)
        try r.sql("""
            UPDATE runs SET status='asking',ended_at=NULL WHERE id='t4';
            UPDATE exchanges SET state='asking' WHERE thread_id='t4';
            UPDATE runs SET status='running',ended_at=NULL WHERE id='s4';
            UPDATE sittings SET state='running',ended_at=NULL,verdict=NULL WHERE id='s4';
            UPDATE exchanges SET state='failed',reason='endpoint closed' WHERE thread_id='t3';
            UPDATE runs SET status='failed' WHERE id='t3';
            UPDATE exchanges SET question='first line' || char(10) || 'private second line' WHERE thread_id='t2';
            INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at)
              VALUES('t2',2,'follow-up question','follow-up answer','answered','2030-01-01T12:00:03Z');
            UPDATE exchanges SET question=printf('%.*c',220,'x') WHERE thread_id='t1';
            INSERT INTO outcomes(id,claim_id,source,label,created_at) VALUES
              ('o1','f1','owner','confirmed','2030-01-02T00:00:00Z'),
              ('o2','f1','owner','dismissed','2030-01-03T00:00:00Z'),
              ('o3','f1','git','confirmed','2030-01-04T00:00:00Z'),
              ('o4','f2','owner','will_fix','2030-01-02T00:00:00Z'),
              ('o5','f3','owner','confirmed','2030-01-02T00:00:00Z');
            INSERT INTO proposals VALUES('p1','route','inspect',NULL,'pending',NULL,'2030-01-01T00:00:00Z');
            INSERT INTO proposals VALUES('p2','route','inspect',NULL,'approved','p1','2030-01-02T00:00:00Z');
            INSERT INTO proposals VALUES('p3','route','inspect',NULL,'pending',NULL,'2030-01-03T00:00:00Z');
            INSERT INTO seat_runs(id,run_id,seat,harness,model_id,started_at,cost_usd) VALUES
              ('cost1','s1','a','codex','test-model',strftime('%Y-%m-%dT%H:%M:%SZ','now','-6 days','weekday 1','start of day'),1.25),
              ('cost2','t2','b','claude','test-model',strftime('%Y-%m-%dT%H:%M:%SZ','now'),2.5),
              ('old','s3','a','codex','test-model',strftime('%Y-%m-%dT%H:%M:%SZ','now','-6 days','weekday 1','start of day','-1 second'),99);
            """)
        let before = try r.sql("SELECT count(*) FROM requests;")
        let json = try r.panel(); let data = try PanelData(json: json)
        #expect(data.configured && data.live == 2)
        #expect(data.seats.total == 4)
        #expect(Set(data.seats.items.map(\.name)) == Set(["a", "b", "c", "d"]))
        #expect(data.seats.items.allSatisfy { $0.model == "test-model" })
        #expect(data.seats.up == data.seats.items.filter(\.up).count)
        #expect(data.seats.thinking == data.seats.items.filter(\.thinking).count)
        #expect(data.proposalsPending == 1)
        #expect(data.week.spendUSD == 3.75)
        #expect(data.week.budgetUSD == nil)
        #expect(data.threads.map(\.id) == ["t4", "t3", "t2", "t1"])
        #expect(data.sittings.map(\.id) == ["s4", "s3", "s2", "s1"])
        #expect(data.findings.map(\.id) == ["f4", "f3", "f2", "f1"])
        #expect(data.findings.map(\.disposition) == ["open", "confirmed", "will_fix", "dismissed"])
        #expect(data.threads[0].state == "asking" && data.threads[0].reason == nil)
        #expect(data.threads[1].state == "failed" && data.threads[1].reason == "endpoint closed")
        #expect(data.threads[2].question == "first line")
        #expect(data.threads[3].question == String(repeating: "x", count: 200))
        #expect(data.sittings[0].state == "running" && data.sittings[0].ended == nil)
        #expect(data.sittings[3].costUSD == 1.25)
        #expect(data.sittings[3].verdict == "PASS")
        #expect(data.findings.allSatisfy { $0.file == "src/main.swift" && $0.line == 7 && $0.body == "Inspect boundary" })
        _ = try r.panel()
        #expect(try r.sql("SELECT count(*) FROM requests;") == before)
    }

    @Test func weeklyCapsSumOnlyWeeklyDollarBudgetsAndConfigurationRequiresBothCollections() throws {
        let r = try U8Rig()
        let budgets: [[String: Any]] = [
            ["name": "one", "scope": "root", "key": "owner", "window": "week", "dollars": 10],
            ["name": "two", "scope": "vendor", "key": "google", "window": "week", "dollars": 20],
            ["name": "run", "scope": "root", "key": "owner", "window": "run", "dollars": 99]
        ]
        try r.council.configure(raw: ["budgets": try u6aText(budgets)])
        #expect(try PanelData(json: r.panel()).week.budgetUSD == 30)
        try r.council.configure(councils: [])
        #expect(try PanelData(json: r.panel()).configured == false)
        try r.council.base.config(seats: [], routes: [], raw: ["councils": "[]"])
        #expect(try PanelData(json: r.panel()).configured == false)
    }

    @Test func allThreeListsCapAtTwoHundredNewestRows() throws {
        let r = try U8Rig(); try r.seed(203)
        try r.sql("""
            UPDATE runs SET status='asking',ended_at=NULL WHERE id='t1';
            UPDATE exchanges SET state='asking' WHERE thread_id='t1';
            UPDATE runs SET status='running',ended_at=NULL WHERE id='s1';
            UPDATE sittings SET state='running',ended_at=NULL,verdict=NULL WHERE id='s1';
            INSERT INTO claims(id,run_id,body,severity,file,line,created_at)
              VALUES('thread-claim','t2','Not a sitting claim','p1','src/main.swift',1,'2031-01-01T00:00:00Z');
            """)
        let data = try PanelData(json: r.panel())
        #expect(data.live == 2)
        #expect(data.threads.count == 200 && data.sittings.count == 200 && data.findings.count == 200)
        #expect(data.threads.map(\.id) == (4...203).reversed().map { "t\($0)" })
        #expect(data.sittings.map(\.id) == (4...203).reversed().map { "s\($0)" })
        #expect(data.findings.map(\.id) == (4...203).reversed().map { "f\($0)" })
    }

    @Test func ledgerAndConfigProblemsReturnFailureWithoutPartialData() throws {
        let r = try U8Rig(); try r.seed()
        try r.council.configure(raw: ["notify": "[\"unknown\"]"])
        let invalid = try r.home.request(["op": "panel"])
        #expect(invalid["ok"] as? Bool == false)
        #expect(invalid["data"] == nil)
        #expect((invalid["error"] as? String)?.contains("notify") == true)
        try r.council.configure()
        // Corrupt only this isolated fixture's schema while the real broker is alive.
        try r.sql("ALTER TABLE claims RENAME TO missing_claims;")
        let broken = try r.home.request(["op": "panel"])
        #expect(broken["ok"] as? Bool == false)
        #expect(broken["data"] == nil)
        #expect(!(broken["error"] as? String ?? "").isEmpty)
    }

    @Test func bentoCountsOnlyOwnerWorkAndRecentUnseenFailures() throws {
        let dispositions = ["open", "open", "open", "confirmed", "confirmed", "dismissed", "will_fix"]
        let base = u8JSON(dispositions: dispositions, proposals: 1)
        #expect(PanelModel.bento(try u8Data(base), seen: [], now: u8Now) ==
                .needsYou(count: 4, findings: 3, proposals: 1, stopped: 0))
        let stopped = u8JSON(sittings: [u8Sitting("s1", "INCOMPLETE")], dispositions: dispositions, proposals: 1)
        #expect(PanelModel.bento(try u8Data(stopped), seen: [], now: u8Now) ==
                .needsYou(count: 5, findings: 3, proposals: 1, stopped: 1))
        #expect(PanelModel.bento(try u8Data(stopped), seen: ["s1"], now: u8Now) ==
                .needsYou(count: 4, findings: 3, proposals: 1, stopped: 0))
        let old = "2029-12-31T11:59:59Z"
        let rows = [u8Sitting("old", "INCOMPLETE", started: old), u8Sitting("failed", "failed"),
                    u8Sitting("stopped", "stopped"), u8Sitting("block", "BLOCK"), u8Sitting("pass", "PASS")]
        #expect(PanelModel.bento(try u8Data(u8JSON(sittings: rows)), seen: [], now: u8Now) ==
                .needsYou(count: 1, findings: 0, proposals: 0, stopped: 1))
        #expect(PanelModel.bento(try u8Data(u8JSON(configured: false)), seen: [], now: u8Now) == .firstStep)
        let live = [u8Sitting("new", "running"), u8Sitting("older", "running", started: old)]
        #expect(PanelModel.bento(try u8Data(u8JSON(sittings: live)), seen: [], now: u8Now) == .council(sitting: "new"))
    }

    @Test func notifierTransitionsAreDistinctAndNeverReplayOnFirstRead() throws {
        let settings = try NotifySettings(values: [:])
        let running = try u8Data(u8JSON(sittings: [u8Sitting("s1", "running")], threads: [u8Thread("asking")]))
        for state in ["PASS", "INCOMPLETE", "BLOCK", "failed", "stopped"] {
            let final = try u8Data(u8JSON(sittings: [u8Sitting("s1", state)]))
            #expect(Notifier.events(previous: nil, current: final, settings: settings).isEmpty)
            let expected: [PanelEvent] = state == "BLOCK" ? [.block(sitting: "s1")] :
                ["PASS", "INCOMPLETE"].contains(state) ? [.verdict(sitting: "s1", verdict: state)] : []
            #expect(Notifier.events(previous: running, current: final, settings: settings) == expected)
            #expect(Notifier.events(previous: final, current: final, settings: settings).isEmpty)
        }
        let failed = try u8Data(u8JSON(up: false, threads: [u8Thread("failed")]))
        let events = Notifier.events(previous: running, current: failed, settings: settings)
        #expect(events.count == 2)
        #expect(events.contains(.seatDied(seat: "a")))
        #expect(events.contains(.threadFailed(thread: "t1")))
        #expect(Notifier.events(previous: failed, current: failed, settings: settings).isEmpty)
        #expect(Notifier.events(previous: nil, current: failed, settings: settings).isEmpty)
    }

    @Test func budgetCrossesAtEightyOnceAndRearmsBelowIt() throws {
        let settings = try NotifySettings(values: [:])
        func data(_ spend: Double) throws -> PanelData { try u8Data(u8JSON(spend: spend, budget: 100)) }
        #expect(Notifier.events(previous: try data(79), current: try data(80), settings: settings) == [.budget(percent: 80)])
        #expect(Notifier.events(previous: try data(80), current: try data(90), settings: settings).isEmpty)
        #expect(Notifier.events(previous: try data(90), current: try data(79), settings: settings).isEmpty)
        #expect(Notifier.events(previous: try data(79), current: try data(81), settings: settings) == [.budget(percent: 81)])
        #expect(Notifier.events(previous: nil, current: try data(90), settings: settings).isEmpty)
        #expect(Notifier.events(previous: try u8Data(), current: try u8Data(u8JSON(spend: 90)), settings: settings).isEmpty)
    }

    @Test func notifyDefaultsValidationAndEachDisabledKind() throws {
        let kinds: Set<String> = ["verdict", "block", "seat", "budget", "thread"]
        #expect(try NotifySettings(values: [:]).notify == kinds)
        for text in ["null", "{}", "true", "1", "\"verdict\"", "[1]", "[\"unknown\"]", "["] {
            do { _ = try NotifySettings(values: ["notify": text]); Issue.record("Accepted invalid notify: \(text)") }
            catch let error as ConfigProblem { #expect(error.key == "notify") }
            catch { Issue.record("Wrong error: \(error)") }
            do { _ = try SeatConfig(values: ["notify": text]); Issue.record("SeatConfig accepted invalid notify") }
            catch let error as ConfigProblem { #expect(error.key == "notify") }
            catch { Issue.record("Wrong config error: \(error)") }
        }
        #expect(try NotifySettings(values: ["notify": "[]"]).notify.isEmpty)
        let previous = try u8Data(u8JSON(sittings: [u8Sitting("s1", "running")], spend: 79, budget: 100,
                                        threads: [u8Thread("asking")]))
        for (kind, event) in [("verdict", PanelEvent.verdict(sitting: "s1", verdict: "PASS")),
                               ("block", .block(sitting: "s1")), ("seat", .seatDied(seat: "a")),
                               ("budget", .budget(percent: 81)), ("thread", .threadFailed(thread: "t1"))] {
            let settings = try NotifySettings(values: ["notify": try u6aText(kinds.subtracting([kind]).sorted())])
            let current = try u8Data(u8JSON(sittings: [u8Sitting("s1", kind == "block" ? "BLOCK" : "PASS")],
                spend: 81, budget: 100, up: false, threads: [u8Thread("failed")]))
            #expect(!Notifier.events(previous: previous, current: current, settings: settings).contains(event))
        }
    }

    @Test @MainActor func stopIsImmediateDeduplicatedAndWaitsForFinalRead() async throws {
        let gate = U8StopGate()
        let control = StopControl(stop: { await gate.stop($0) })
        #expect(control.state(for: "s1") == .idle(reason: nil))
        let first = Task { await control.press("s1") }
        await gate.waitForEntry()
        #expect(control.state(for: "s1") == .stopping)
        await control.press("s1")
        #expect(gate.calls == ["s1"])
        gate.finish(); await first.value
        #expect(control.state(for: "s1") == .stopping)
        control.observe(try u8Data(u8JSON(sittings: [u8Sitting("s1", "running")])))
        #expect(control.state(for: "s1") == .stopping)
        control.observe(try u8Data(u8JSON(sittings: [u8Sitting("s1", "stopped")])))
        #expect(control.state(for: "s1") == .idle(reason: nil))
    }

    @Test @MainActor func failedStopReturnsToIdleWithReasonAndCanRetry() async {
        struct Refused: LocalizedError { var errorDescription: String? { "stop refused: ledger unavailable" } }
        var calls = 0
        let control = StopControl(stop: { _ in calls += 1; throw Refused() })
        await control.press("s1")
        #expect(control.state(for: "s1") == .idle(reason: "stop refused: ledger unavailable"))
        await control.press("s1")
        #expect(calls == 2)
    }
}
