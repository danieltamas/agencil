import AgencilCore
import Foundation

/// Made-up `detail` replies for the preview and the screenshots, in the broker's wire shape.
extension DemoPanel {
    /// A finding body as the ledger keeps it: JSON when the seat gave a fix or a confidence, the plain claim otherwise.
    static func ledgerBody(_ finding: Finding) -> String {
        guard let fix = finding.fix, let confidence = finding.confidence.flatMap({ Double($0.dropLast()) }) else { return finding.claim }
        let object: [String: Any] = ["confidence": confidence / 100, "evidence": finding.claim, "fix": fix]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? finding.claim
    }

    private static func stamp(_ offset: Double) -> String { ISO8601DateFormatter().string(from: DemoStore.now.addingTimeInterval(offset)) }

    private static let blindAnswer = """
        {"claims": [{"id": "c1", "kind": "defect", "severity": "p1", "confidence": 0.95, "file": "src/charge.ts", "line": 88, \
        "evidence": "The retry re-sends the idempotency key with a new body.", "fix": "Keep the first body."}], \
        "vote": "block", "notes": "One blocker in the retry path."}
        """

    static func detailJSON(_ id: String) -> [String: Any]? {
        switch id {
        case "t1":
            return ["thread": id, "caller": "claude", "seat": "codex-gpt",
                    "exchanges": [["seq": 1, "question": threads[0].question, "state": "asking"]]]
        case "t2":
            return ["thread": id, "caller": "opencode", "seat": "claude-opus", "model": "claude-opus-4-1", "harness": "claude",
                    "project": "orbit-web  ~/Sites/orbit-web", "exchanges": [
                ["seq": 1, "question": threads[1].question + "\nThe migration adds a NOT NULL column and backfills it in the next file.",
                 "state": "answered", "cost_usd": 0.07, "tokens": 5200,
                 "answer": "**Reorder them.** `0042_orders.sql` adds `region` as NOT NULL before `0043_backfill.sql` fills it, so the first migration fails on a non-empty table.\n\n```sql\n-- 0042_orders.sql\nALTER TABLE orders ADD COLUMN region text;\n\n-- 0043_backfill.sql\nUPDATE orders o\nSET region = c.region\nFROM customers c\nWHERE c.id = o.customer_id\n  AND o.region IS NULL;\n\n-- 0044_region_not_null.sql\nALTER TABLE orders\n  ALTER COLUMN region SET NOT NULL;\n```\n\n- Add the column as nullable in 0042.\n- Backfill in 0043.\n- Set NOT NULL in a third file."],
            ]]
        case "t3":
            return ["thread": id, "caller": "codex", "seat": "box-qwen3",
                    "exchanges": [["seq": 1, "question": threads[2].question, "state": "failed", "reason": "endpoint closed the connection"]]]
        case "s1", "s2":
            return sittingJSON(id)
        default:
            return nil
        }
    }

    private static func sittingJSON(_ id: String) -> [String: Any] {
        let done = id == "s2"
        var seats: [[String: Any]] = [
            ["seat": "codex-gpt", "thread": "th_demo1", "state": "answered", "started": stamp(-3500), "ended": stamp(-3440), "cost_usd": 0.21, "answer": blindAnswer],
            ["seat": "claude-opus", "thread": "th_demo2", "state": "answered", "started": stamp(-3500), "ended": stamp(-3410), "answer": blindAnswer],
        ]
        if !done { seats[1] = ["seat": "claude-opus", "thread": "th_demo2", "state": "asking", "started": stamp(-30)] }
        var detail: [String: Any] = [
            "sitting": id, "no": done ? 213 : 214, "council": done ? "security" : "code-review", "state": done ? "done" : "running",
            "round": done ? "verdict" : "blind", "project": "lumen-api  ~/Sites/lumen-api", "snapshot": "snap_4f1c9a", "repo": "lumen/api",
            "brief": "Change kind: auth\nQuestion: Is the cursor binding in api/orders.rs safe across tenants?\nDiff: main..orders-cursor",
            "change_kind": "auth", "question": "Is the cursor binding in api/orders.rs safe across tenants?", "diff_range": "main..orders-cursor",
            "rounds": [["round": "blind", "seats": seats]],
            "verdict": NSNull(),
        ]
        guard done else { return detail }
        detail["rounds"] = [["round": "blind", "seats": seats],
                            ["round": "rebuttal", "seats": seats.map { $0.merging(["answer": "{\"assessments\": [{\"claim\": \"c1\", \"stance\": \"support\", \"why\": \"Confirmed in the diff.\"}], \"vote\": \"block\"}"]) { _, new in new } }]]
        detail["verdict"] = [
            "verdict": "BLOCK", "reasons": ["One p1 claim stands: the cursor is not bound to the caller.", "Both seats back it."], "rule": "block on any p1",
            "votes": [["seat": "codex-gpt", "state": "answered", "vote": "block"], ["seat": "claude-opus", "state": "answered", "vote": "block"]],
            "claims": [["id": "c1", "seat": "codex-gpt", "kind": "defect", "severity": "p1", "confidence": 0.95, "file": "api/orders.rs", "line": 140,
                        "evidence": "Pagination cursor is not bound to the caller, so a cursor from another tenant is accepted.",
                        "fix": "Sign the cursor with the tenant id.", "backers": ["codex-gpt", "claude-opus"], "dissenters": [], "minority": false, "refuted": false]],
        ] as [String: Any]
        return detail
    }
}
