import AgencilCore
import Foundation
import Testing

/* API contract (all production symbols below belong to AgencilCore and are public).
 PanelData: Sendable plain value structs, no Codable requirement.
 init(json: [String: Any]) throws decodes exactly docs/U8-SPEC.md's data object;
 properties use Swift camelCase: configured, seats (total/up/thinking/items), threads,
 sittings, findings, proposalsPending, week (spendUSD/budgetUSD), live. Collections
 retain broker order. Row properties mirror JSON keys (costUSD, probedAgo).
 Dates decode ISO8601 UTC text; nullable fields are Optional. Names/states are String.
 Nested public value types: PanelData.Seats(total/up/thinking: Int, items: [SeatItem]);
 SeatItem(name/model: String, up/thinking: Bool, probedAgo: Double?);
 Thread(id/caller/seat/question/state: String, reason: String?, started: Date, ended: Date?);
 Sitting(id/council/state/round: String, no: Int, started: Date, ended: Date?,
         costUSD: Double, verdict: String?);
 Finding(id/severity/file/body/disposition: String, line/backers/dissenters: Int,
         minority: Bool); Week(spendUSD: Double, budgetUSD: Double?).
 PanelData has configured: Bool, seats: Seats, threads: [Thread], sittings: [Sitting],
 findings: [Finding], proposalsPending/live: Int, week: Week. All properties public.
 PanelModel.bento(_ data: PanelData, seen: Set<String>, now: Date) -> Bento
 Bento: Equatable, Sendable enum: firstStep; council(sitting: String);
 needsYou(count: Int, findings: Int, proposals: Int, stopped: Int).
 NotifySettings: Sendable, init(values: [String: String]) throws; notify: Set<String>.
 Missing notify enables all five kinds; invalid JSON/type/kind throws ConfigProblem
 with key == "notify". SeatConfig.init(values:) also validates this key.
 Notifier.events(previous: PanelData?, current: PanelData,
                 settings: NotifySettings) -> [PanelEvent]
 PanelEvent: Equatable, Sendable enum: verdict(sitting: String, verdict: String),
 block(sitting: String), seatDied(seat: String), budget(percent: Double),
 threadFailed(thread: String). Percent is in 0...100 units, not a fraction.
 StopControl: public @MainActor final class; init(stop: @escaping @MainActor
 (String) async throws -> Void); state(for: String) -> State;
 press(_ id: String) async; observe(_ data: PanelData).
 State: public Equatable enum with idle(reason: String?) and stopping.
 Successful stop waits for observe's final sitting state; errors use
 LocalizedError.errorDescription as the idle reason. No process work in this type.
 */

let u8Now = Date(timeIntervalSince1970: 1_893_499_200)
let u8Started = "2030-01-01T12:00:00Z"

func u8Sitting(_ id: String = "s1", _ state: String = "PASS",
               started: String = u8Started) -> [String: Any] {
    ["id": id, "no": 1, "council": "panel", "state": state, "round": "blind",
     "started": started, "cost_usd": 0.5]
}
func u8Thread(_ state: String) -> [String: Any] {
    ["id": "t1", "caller": "owner", "seat": "a", "question": "Inspect", "state": state,
     "started": u8Started].merging(state == "failed" ? ["reason": "endpoint closed"] : [:]) { _, b in b }
}
func u8JSON(configured: Bool = true, sittings: [[String: Any]] = [],
            dispositions: [String] = [], proposals: Int = 0, spend: Double = 0,
            budget: Double? = nil, up: Bool = true, threads: [[String: Any]] = []) -> [String: Any] {
    var week: [String: Any] = ["spend_usd": spend]
    if let budget { week["budget_usd"] = budget }
    return ["configured": configured,
        "seats": ["total": 1, "up": up ? 1 : 0, "thinking": 0,
                  "items": [["name": "a", "model": "test-model", "up": up, "thinking": false]]],
        "threads": threads, "sittings": sittings,
        "findings": dispositions.enumerated().map { index, disposition in
            ["id": "f\(index)", "severity": "p1", "file": "src/main.swift", "line": 1,
             "body": "Inspect boundary", "backers": 2, "dissenters": 1,
             "minority": true, "disposition": disposition] as [String: Any]
        }, "proposals_pending": proposals, "week": week,
        "live": sittings.filter { $0["state"] as? String == "running" }.count +
            threads.filter { $0["state"] as? String == "asking" }.count]
}
func u8Data(_ json: [String: Any] = u8JSON()) throws -> PanelData { try PanelData(json: json) }

// Reuses U7b's real broker, isolated home and stub installs, without changing its helpers.
final class U8Rig {
    let trigger: U7bRig
    var council: U7aRig { trigger.council }
    var home: BrokerHome { trigger.home }
    init() throws { trigger = try U7bRig() }
    func panel() throws -> [String: Any] { try council.base.data(home.request(["op": "panel"])) }
    func rows(_ json: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(json[key] as? [[String: Any]])
    }
    @discardableResult func sql(_ statement: String) throws -> String {
        let process = try BrokerProcess(["-bail", home.url.appendingPathComponent("agencil.sqlite").path,
                                         statement], home: home.url,
                                        executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
        let (code, out, error) = try process.finish()
        try #require(code == 0, "Fixture SQL failed: \(error)")
        return out
    }
    func seed(_ count: Int = 1) throws {
        // Final rows only: the broker's restart recovery must not race fixture writes.
        for n in 1...count {
            let time = String(format: "2030-01-%02dT12:%02d:%02dZ", 1 + n / 3600, (n / 60) % 60, n % 60)
            try sql("""
                INSERT INTO runs(id,kind,status,started_at,ended_at) VALUES('s\(n)','sitting','PASS','\(time)','\(time)');
                INSERT INTO sittings VALUES('s\(n)',\(n),'panel','PASS','blind','google','snapshot','', 'PASS','\(time)','\(time)');
                INSERT INTO runs(id,kind,status,started_at,ended_at) VALUES('t\(n)','thread','answered','\(time)','\(time)');
                INSERT INTO threads VALUES('t\(n)','a','a','owner',NULL,'\(time)');
                INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at)
                  VALUES('t\(n)',1,'Inspect boundary','answer','answered','\(time)');
                INSERT INTO claims(id,run_id,body,severity,file,line,created_at)
                  VALUES('f\(n)','s\(n)','Inspect boundary','p1','src/main.swift',7,'\(time)');
                """)
        }
    }
}

@MainActor final class U8StopGate {
    var calls: [String] = []
    var entered: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    func stop(_ id: String) async {
        calls.append(id)
        await withCheckedContinuation { continuation in
            release = continuation
            entered?.resume(); entered = nil
        }
    }
    func waitForEntry() async {
        if release != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func finish() { release?.resume(); release = nil }
}
