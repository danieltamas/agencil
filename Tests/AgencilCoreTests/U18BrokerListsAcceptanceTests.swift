import Foundation
import Testing
import AgencilCore

@Suite(.serialized)
struct U18BrokerListsAcceptanceTests {
    private func data(_ home: BrokerHome, _ op: String,
                      caller: String = "owner", extra: [String: Any] = [:]) throws -> [String: Any] {
        let reply = try home.request(["op": op, "caller": caller].merging(extra) { _, b in b })
        #expect(reply["ok"] as? Bool == true)
        #expect(reply.keys.contains("data_note"))
        return try #require(reply["data"] as? [String: Any])
    }

    private func rows(_ home: BrokerHome, _ op: String, caller: String = "owner",
                      extra: [String: Any] = [:]) throws -> [[String: Any]] {
        try #require(data(home, op, caller: caller, extra: extra)[op] as? [[String: Any]])
    }

    private func equal(_ actual: Any, _ expected: Any) throws {
        #expect(try u6aText(actual) == u6aText(expected))
    }

    private func failure(_ home: BrokerHome, _ op: String, exit: Int,
                         caller: String = "owner", extra: [String: Any] = [:],
                         message: String? = nil) throws {
        let reply = try home.request(["op": op, "caller": caller].merging(extra) { _, b in b })
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == exit)
        #expect(reply["data"] == nil)
        let error = try #require(reply["error"] as? String)
        #expect(!error.isEmpty)
        if let message { #expect(error == message) }
    }

    private func configure(_ rig: U6aRig, sharedModel: Bool = false) throws {
        let seats = [
            u6aSeat("zeta", extra: ["model": "z-model", "vendor": "harbor", "hosted": true,
                "endpoint": "https://example.invalid/private-seat", "pin": "PRIVATE_PIN_Z"]),
            u6aSeat("alpha", "claude", extra: ["model": sharedModel ? "z-model" : "a-model",
                "vendor": "lumen", "hosted": false, "role": "answerer", "pin": "PRIVATE_PIN_A"])
        ]
        let council: [String: Any] = ["name": "review", "seats": ["zeta"], "spare": ["alpha"],
                                     "rule": "majority", "high_risk": false]
        let routes: [[String: Any]] = [
            ["callers": ["codex"], "target": "zeta", "hop_limit": 3, "fallbacks": ["alpha"]],
            ["callers": ["owner"], "target": "review", "hop_limit": 2,
             "fallbacks": [], "residency": "local"]
        ]
        try rig.config(seats: seats, routes: routes, aliases: ["helper": "zeta"],
                       raw: ["councils": try u6aText([council]), "agent_access": "on"])
    }

    @Test func configuredListsHaveExactPublicRowsAndNeverExposePrivateConfiguration() throws {
        let rig = try U6aRig(); try configure(rig)
        let expected: [String: [[String: Any]]] = [
            "seats": [
                ["name": "zeta", "harness": "codex", "model": "z-model", "role": "answerer",
                 "hosted": true, "vendor": "harbor"],
                ["name": "alpha", "harness": "claude", "model": "a-model", "role": "answerer",
                 "hosted": false, "vendor": "lumen"]
            ],
            "councils": [["name": "review", "seats": ["zeta"], "spares": ["alpha"],
                          "synthesizers": [], "rule": "majority", "high_risk": false, "mode": "review"]],
            "routes": [
                ["callers": ["codex"], "target": "zeta", "hop_limit": 3,
                 "fallbacks": ["alpha"], "local_only": false],
                ["callers": ["owner"], "target": "review", "hop_limit": 2,
                 "fallbacks": [], "local_only": true]
            ],
            "models": [["model": "a-model", "seats": ["alpha"]],
                       ["model": "z-model", "seats": ["zeta"]]]
        ]
        for op in ["seats", "councils", "routes", "models", "list_targets"] {
            let reply = try rig.home.request(["op": op, "caller": "owner"])
            #expect(reply["ok"] as? Bool == true)
            #expect(reply.keys.contains("data_note"))
            let text = try u6aText(reply)
            for secret in ["https://example.invalid/private-seat", "PRIVATE_PIN_Z", "PRIVATE_PIN_A"] {
                #expect(!text.contains(secret))
            }
            if let expectedRows = expected[op] {
                let object = try #require(reply["data"] as? [String: Any])
                try equal(try #require(object[op]), expectedRows)
            }
        }
        try configure(rig, sharedModel: true)
        try equal(rows(rig.home, "models"), [["model": "z-model", "seats": ["zeta", "alpha"]]])
        rig.noAnswerSpawned()
    }

    @Test func targetVisibilityUsesCallerRoutesAliasesAndOwnerMaximumHopLimit() throws {
        let rig = try U6aRig(); try configure(rig)
        try equal(rows(rig.home, "list_targets"), [
            ["target": "alpha", "kind": "seat", "hop_limit": 3],
            ["target": "helper", "kind": "alias", "hop_limit": 3],
            ["target": "review", "kind": "council", "hop_limit": 3, "mode": "review"],
            ["target": "zeta", "kind": "seat", "hop_limit": 3]
        ])
        try equal(rows(rig.home, "list_targets", caller: "codex"), [
            ["target": "helper", "kind": "alias", "hop_limit": 3],
            ["target": "zeta", "kind": "seat", "hop_limit": 3]
        ])
        #expect(try rows(rig.home, "list_targets", caller: "unrouted").isEmpty)
        try rig.config(routes: [], aliases: ["helper": "primary"], raw: ["agent_access": "on"])
        try equal(rows(rig.home, "list_targets"), [
            ["target": "helper", "kind": "alias", "hop_limit": 1],
            ["target": "primary", "kind": "seat", "hop_limit": 1]
        ])
        try rig.config(routes: [u6aRoute(callers: ["any"])],
                       aliases: ["helper": "primary"], raw: ["agent_access": "on"])
        try equal(rows(rig.home, "list_targets", caller: "unrouted"), [
            ["target": "helper", "kind": "alias", "hop_limit": 2],
            ["target": "primary", "kind": "seat", "hop_limit": 2]
        ])
        for access in ["off", ""] {
            try rig.config(raw: ["agent_access": access])
            try failure(rig.home, "list_targets", exit: 3, caller: "codex",
                        message: "refused: agent access is off")
            #expect(try rows(rig.home, "list_targets").count == 1)
        }
    }

    @Test func findingsMatchPanelAndOwnerDecisionsPersistAndSupersede() throws {
        let rig = try U8Rig(); try rig.seed(2)
        let initial = try rows(rig.home, "findings")
        #expect(initial.compactMap { $0["id"] as? String } == ["f2", "f1"])
        #expect(initial.allSatisfy { $0["disposition"] as? String == "open" })
        try equal(initial, try #require(rig.panel()["findings"]))
        try equal(rows(rig.home, "findings", extra: ["open": true]), initial)
        try equal(data(rig.home, "dispose", extra: ["id": "f1", "disposition": "confirm"]),
                  ["id": "f1", "disposition": "confirm"])
        #expect(try rig.sql("SELECT source,certainty,label FROM outcomes WHERE claim_id='f1';") ==
                "owner|final|confirmed\n")
        #expect(try rig.sql("SELECT label FROM outcomes WHERE claim_id='f1' AND source='owner';") ==
                "confirmed\n")
        #expect(try rows(rig.home, "findings", extra: ["open": true])
            .compactMap { $0["id"] as? String } == ["f2"])
        try equal(rows(rig.home, "findings", extra: ["open": false]),
                  try #require(rig.panel()["findings"]))
        try equal(data(rig.home, "dispose", extra: ["id": "f1", "disposition": "dismiss"]),
                  ["id": "f1", "disposition": "dismiss"])
        #expect(try rig.sql("SELECT label FROM outcomes WHERE claim_id='f1' AND source='owner' ORDER BY created_at, id;") ==
                "confirmed\nrefuted\n")
        #expect(try rig.sql("SELECT count(*) FROM outcomes WHERE claim_id='f1' AND source='owner';") == "2\n")
        try equal(rows(rig.home, "findings"), try #require(rig.panel()["findings"]))
    }

    @Test func rejectedDispositionsNeverWriteOutcomes() throws {
        let rig = try U8Rig(); try rig.seed()
        try failure(rig.home, "dispose", exit: 64,
                    extra: ["id": "missing", "disposition": "confirm"], message: "unknown id missing")
        try failure(rig.home, "dispose", exit: 64,
                    extra: ["id": "f1", "disposition": "will-fix"], message: "will-fix is not recorded yet")
        for disposition in ["confirm", "dismiss", "will-fix"] {
            try failure(rig.home, "dispose", exit: 3, caller: "codex",
                        extra: ["id": "f1", "disposition": disposition])
        }
        #expect(try rig.sql("SELECT count(*) FROM outcomes;") == "0\n")
        #expect(try rows(rig.home, "findings", extra: ["open": true]).count == 1)
    }

    @Test func leaderboardPreviewIsValidatedJSONAndOwnerOnly() throws {
        let rig = try U8Rig(); try rig.seed()
        let preview = try data(rig.home, "leaderboard", extra: ["action": "preview"])
        #expect(Set(preview.keys) == ["bytes", "cells"])
        let bytes = Data(try #require(preview["bytes"] as? String).utf8)
        try LeaderboardValidator.validate(bytes, aliasesOnMain: [])
        let document = try brokerJSON(bytes)
        let cells = try #require(document["cells"] as? [[String: Any]])
        #expect(preview["cells"] as? Int == cells.count)
        #expect(cells.isEmpty)
        for action in ["preview", "publish"] {
            try failure(rig.home, "leaderboard", exit: 3, caller: "codex", extra: ["action": action])
        }
        try failure(rig.home, "leaderboard", exit: 64, extra: ["action": "unknown"])
        try rig.council.configure(raw: ["leaderboard_min_n": "invalid"])
        try failure(rig.home, "leaderboard", exit: 4, extra: ["action": "preview"],
                    message: "leaderboard_min_n must be a whole number")
    }

    @Test func emptyHomeReturnsEmptyLists() throws {
        let home = try BrokerHome()
        let broker = try home.serve(); defer { broker.kill() }
        for op in ["seats", "councils", "routes", "models", "list_targets", "findings"] {
            #expect(try rows(home, op).isEmpty)
        }
    }

    @Test func invalidConfigurationFailsClosedWithoutPartialLists() throws {
        let rig = try U8Rig(); try rig.seed()
        try rig.council.configure(raw: ["seats": "not-json"])
        for op in ["seats", "councils", "routes", "models", "list_targets", "findings", "dispose", "leaderboard"] {
            try failure(rig.home, op, exit: 4,
                        extra: ["id": "f1", "disposition": "confirm", "action": "preview"])
        }
        #expect(try rig.sql("SELECT count(*) FROM outcomes;") == "0\n")
    }
}
