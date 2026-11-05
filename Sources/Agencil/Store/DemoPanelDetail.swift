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
        case "s3":
            return consultJSON()
        default:
            return nil
        }
    }

    static let consultQuestion = "Should harbor/checkout keep its session store in Postgres or move it to Redis?"

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A consult sitting whose two seats split: claude-opus moves after the review, codex-gpt holds and ends in the minority.
    private static func consultJSON() -> [String: Any] {
        let index = "Keep sessions in Postgres and add a partial index on expires_at."
        let later = "Keep Postgres now; move to Redis once session reads pass 10k per minute."
        let redis = "Move sessions to Redis with a 30-day TTL."
        let indexReasoning = "Session reads are **1.2k per minute**, well inside what the primary serves today."
        let indexCrux = "Reads above 10k per minute, or lock waits on the sessions table."
        let redisReasoning = "Expiry becomes free and the primary stops carrying session churn."
        let redisCrux = "A need to join sessions to other tables in SQL."
        let moved = "The churn argument holds once reads grow; the measured rate says not yet."
        let opusBlind: [String: Any] = ["position": index, "confidence": 0.7, "reasoning": indexReasoning, "crux": indexCrux,
                                        "questions_back": ["What read rate do you expect at launch?"]]
        let codexBlind: [String: Any] = ["position": redis, "confidence": 0.8, "reasoning": redisReasoning, "crux": redisCrux]
        let opusReview: [String: Any] = ["position": later, "confidence": 0.65, "reasoning": indexReasoning, "crux": indexCrux,
                                         "questions_back": ["What read rate do you expect at launch?"], "kept": false, "because": moved,
                                         "new_evidence": true, "assessments": [["position": "P2", "stance": "disagree", "why": "TTL expiry alone does not justify a new store."]]]
        let codexReview: [String: Any] = ["position": redis, "confidence": 0.75, "reasoning": redisReasoning, "crux": redisCrux, "kept": true,
                                          "assessments": [["position": "P1", "stance": "partly", "why": "The index helps, but churn still lands on the primary."]]]
        func seat(_ name: String, _ answer: [String: Any], _ start: Double) -> [String: Any] {
            ["seat": name, "state": "answered", "started": stamp(start), "ended": stamp(start + 50), "cost_usd": 0.09, "answer": json(answer)]
        }
        let summary = """
            ## Answer
            Keep sessions in Postgres for now (medium confidence); revisit at 10k reads per minute.

            ## Positions
            - Keep Postgres now, Redis past 10k reads per minute: claude-opus (moved from an index-only plan).
            - Move to Redis with a TTL now: codex-gpt.

            ## Disputed
            - Whether TTL expiry alone justifies a new store. Crux: lock waits on the sessions table.

            ## Minority report
            - codex-gpt holds that session churn on the primary is worth removing today.

            ## Questions back
            - What read rate do you expect at launch?
            """
        return [
            "sitting": "s3", "no": 212, "council": "architecture", "state": "done", "round": "verdict", "project": "harbor-checkout  ~/Sites/harbor",
            "snapshot": "snap_9b20e1", "repo": "harbor/checkout", "question": consultQuestion, "change_kind": "plan",
            "brief": "Change kind: plan\nQuestion: " + consultQuestion,
            "rounds": [["round": "blind", "seats": [seat("claude-opus", opusBlind, -7200), seat("codex-gpt", codexBlind, -7190)]],
                       ["round": "rebuttal", "seats": [seat("claude-opus", opusReview, -7100), seat("codex-gpt", codexReview, -7090)]]],
            "summary": summary, "summary_by": "claude-opus",
            "verdict": [
                "mode": "consult", "verdict": "SPLIT", "reasons": ["The seats do not all agree with each other's positions."], "claims": [Any](),
                "independence": [String](), "snapshot": "snap_9b20e1",
                "votes": [["seat": "claude-opus", "vendor": "anthropic", "state": "answered", "valid": true, "reason": NSNull()],
                          ["seat": "codex-gpt", "vendor": "openai", "state": "answered", "valid": true, "reason": NSNull()]],
                "positions": [
                    ["seat": "claude-opus", "vendor": "anthropic", "label": "P1", "blind": ["position": index, "confidence": 0.7],
                     "final": ["position": later, "confidence": 0.65, "reasoning": indexReasoning, "crux": indexCrux],
                     "kept": false, "because": moved, "new_evidence": true, "questions_back": ["What read rate do you expect at launch?"], "minority": false],
                    ["seat": "codex-gpt", "vendor": "openai", "label": "P2", "blind": ["position": redis, "confidence": 0.8],
                     "final": ["position": redis, "confidence": 0.75, "reasoning": redisReasoning, "crux": redisCrux],
                     "kept": true, "questions_back": [String](), "minority": true],
                ],
                "assessments": [["seat": "claude-opus", "about": "codex-gpt", "stance": "disagree", "why": "TTL expiry alone does not justify a new store."],
                                ["seat": "codex-gpt", "about": "claude-opus", "stance": "partly", "why": "The index helps, but churn still lands on the primary."]],
                "minority": [["seat": "codex-gpt", "vendor": "openai", "position": redis]],
            ] as [String: Any],
        ]
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
