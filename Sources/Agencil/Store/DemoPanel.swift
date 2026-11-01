import AgencilCore
import Foundation
/// Made-up panel content for the preview and the screenshots; the live store replaces it in U8.
enum DemoPanel {
    struct Thread: Identifiable { let id: String; let caller: String; let seat: String; let question: String; let state: String; let live: Bool; let failed: Bool }
    struct Sitting: Identifiable {
        let id: String; let kind: String; let hue: Int; let target: String; let wokenBy: String
        let state: String; let seats: Int; let elapsed: String; let cost: String; let live: Bool
    }
    struct Finding: Identifiable { let id: String; let severity: String; let place: String; let claim: String; let backers: Int; let dissent: Int }
    struct SeatRow: Identifiable {
        let id: String; let model: String; let up: Bool; let confirmed: String; let coverage: String
        let cost: String; let median: String; let overlap: String; let enough: Bool
    }

    static let threads = [
        Thread(id: "t1", caller: "claude", seat: "codex-gpt", question: "Is the retry in checkout/charge.ts safe to run twice?", state: "asking", live: true, failed: false),
        Thread(id: "t2", caller: "opencode", seat: "claude-opus", question: "Review the migration order in 0042_orders.sql", state: "answered 41s", live: false, failed: false),
        Thread(id: "t3", caller: "codex", seat: "box-qwen3", question: "Summarize the diff in lumen/api#318", state: "failed: endpoint closed the connection", live: false, failed: true),
    ]
    static let sittings = [
        Sitting(id: "s1", kind: "Code", hue: 0, target: "harbor/checkout#214", wokenBy: "maya", state: "Sitting", seats: 3, elapsed: "2m 10s", cost: "$0.42", live: true),
        Sitting(id: "s2", kind: "Security", hue: 3, target: "lumen/api#318", wokenBy: "PR label", state: "BLOCK", seats: 4, elapsed: "6m 02s", cost: "$1.10", live: false),
        Sitting(id: "s3", kind: "Plan", hue: 1, target: "Move sessions to Redis", wokenBy: "jonas", state: "PASS", seats: 3, elapsed: "3m 44s", cost: "$0.61", live: false),
    ]
    static let findings = [
        Finding(id: "f1", severity: "P1", place: "src/charge.ts:88", claim: "The retry re-sends the idempotency key with a new body, so a second charge can pass.", backers: 3, dissent: 0),
        Finding(id: "f2", severity: "P2", place: "api/orders.rs:140", claim: "Pagination cursor is not bound to the caller, so a cursor from another tenant is accepted.", backers: 2, dissent: 1),
        Finding(id: "f3", severity: "P3", place: "web/Cart.tsx:31", claim: "The total is formatted before the currency is known.", backers: 2, dissent: 0),
    ]
    static let seatRows = [
        SeatRow(id: "codex-gpt", model: "gpt-5.5", up: true, confirmed: "61% (48-72)", coverage: "74%", cost: "$0.18", median: "52s", overlap: "92% like claude-opus", enough: true),
        SeatRow(id: "claude-opus", model: "opus-5.5", up: true, confirmed: "68% (55-79)", coverage: "81%", cost: "$0.31", median: "1m 10s", overlap: "92% like codex-gpt", enough: true),
        SeatRow(id: "box-qwen3", model: "qwen3-coder 480b", up: false, confirmed: "n=7, too few", coverage: "n=7, too few", cost: "$0.00", median: "2m 40s", overlap: "none yet", enough: false),
    ]
    static func refresh() async { try? await Task.sleep(for: .seconds(1)) }
    struct ListRow: Identifiable { let name: String; let detail: String; let up: Bool; var id: String { name } }
    static let councils = [
        ListRow(name: "code-review", detail: "3 seats, quorum 2, 2 rounds", up: true),
        ListRow(name: "security", detail: "4 seats, quorum 3, block on any P0", up: true),
        ListRow(name: "plan", detail: "3 seats, quorum 2", up: true),
    ]
    static let routes = [
        ListRow(name: "claude to codex-gpt", detail: "hop limit 2, 20 per hour", up: true),
        ListRow(name: "codex to code-review", detail: "depth 1, budget per day", up: true),
    ]
    static let harnesses = [
        ListRow(name: "claude", detail: "2.3.1", up: true), ListRow(name: "codex", detail: "0.9.4", up: true),
        ListRow(name: "opencode", detail: "1.8.0", up: true), ListRow(name: "hermes", detail: "not installed", up: false),
    ]
    static let polls = "probed 40s, box-qwen3 12s"
}

extension DemoPanel {
    /// The demo rows as a read, for the preview, the screenshots and the layout tests.
    static var data: PanelData? { build(live: true, extraSeats: 0) }

    /// The same read with nothing running; `extraSeats` adds more up seats (the 5-seat perf sitting).
    static func build(live: Bool, extraSeats: Int) -> PanelData? {
        let start = DemoStore.now
        let extras = (0..<extraSeats).map { ["name": "demo-seat-\($0 + 1)", "model": "demo-model", "up": true, "thinking": false] as [String: Any] }
        let running = live ? "running" : "PASS"
        func stamp(_ offset: Double) -> String { ISO8601DateFormatter().string(from: start.addingTimeInterval(offset)) }
        let json: [String: Any] = [
            "configured": true,
            "seats": ["total": 5 + extraSeats, "up": 4 + extraSeats, "thinking": live ? 1 : 0,
                      "items": seatRows.map { ["name": $0.id, "model": $0.model, "up": $0.up, "thinking": live && $0.id == "codex-gpt"] as [String: Any] } + extras],
            "threads": [
                ["id": "t1", "caller": "claude", "seat": "codex-gpt", "question": threads[0].question, "state": live ? "asking" : "answered", "started": stamp(-30)],
                ["id": "t2", "caller": "opencode", "seat": "claude-opus", "question": threads[1].question, "state": "answered",
                 "started": stamp(-300), "ended": stamp(-259)],
                ["id": "t3", "caller": "owner", "seat": "box-qwen3", "question": threads[2].question, "state": "failed",
                 "reason": "endpoint closed the connection", "started": stamp(-600), "ended": stamp(-590)],
            ],
            "sittings": [
                ["id": "s1", "no": 214, "council": "code-review", "state": running, "round": "blind", "started": stamp(-130), "cost_usd": 0.42],
                ["id": "s2", "no": 213, "council": "security", "state": "BLOCK", "round": "verdict", "started": stamp(-3600), "ended": stamp(-3238),
                 "cost_usd": 1.1, "verdict": "BLOCK"],
            ],
            "findings": findings.map { ["id": $0.id, "severity": $0.severity.lowercased(), "file": String($0.place.split(separator: ":")[0]), "line": Int($0.place.split(separator: ":")[1]) ?? 1, "body": $0.claim,
                                         "backers": $0.backers, "dissenters": $0.dissent, "minority": $0.dissent > 0, "disposition": "open"] },
            "proposals_pending": 1, "week": ["spend_usd": 6.4, "budget_usd": 20], "live": live ? 2 : 0,
        ]
        return try? PanelData(json: json)
    }
}
