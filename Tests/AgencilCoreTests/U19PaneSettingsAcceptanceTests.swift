import AgencilCore
import Foundation
import Testing

@Suite(.serialized)
struct U19PaneSettingsAcceptanceTests {
    @Test func scalarSettingsAcceptBoundariesAndPreserveOtherValues() throws {
        let r = try U9Rig()
        for (key, values) in [
            "retention_raw_days": ["1", "90", "3650"],
            "leaderboard_repo": ["harbor/checkout", "lumen/api"],
            "leaderboard_min_n": ["10", "20", "1000"]
        ] {
            for value in values {
                let before = try r.store.read()
                let saved = try r.editor.set(key, value)
                #expect(saved.values[key] == value)
                #expect(saved.revision == before.revision + 1)
                #expect(try r.store.read() == saved)
                for (other, text) in before.values where other != key {
                    #expect(saved.values[other] == text)
                }
                let bytes = try r.bytes()
                #expect(try r.editor.set(key, value) == saved)
                #expect(try r.bytes() == bytes)
            }
        }
    }

    @Test func invalidScalarValuesHaveKeyedProblemsAndNeverWrite() throws {
        let r = try U9Rig()
        let invalid = [
            "retention_raw_days": ["", "0", "-1", "3651", "1.5", "abc", "90days", " 90", "01"],
            "leaderboard_min_n": ["", "9", "0", "-1", "1001", "10.5", "abc"],
            "leaderboard_repo": ["", "harbor", "/checkout", "harbor/", "harbor/checkout/extra", "har bor/api"],
            "leaderboard_enabled": ["", "1", "true", "false", "on", "off", "00", " 0"]
        ]
        for (key, values) in invalid {
            for value in values {
                try r.refuses([key]) { try r.editor.set(key, value) }
            }
        }
        _ = try r.store.update { $0["leaderboard_enabled"] = "1" }
        _ = try r.editor.set("leaderboard_enabled", "0")
        #expect(try r.store.read().values["leaderboard_enabled"] == "0")
        try r.refuses(["leaderboard_enabled"]) { try r.editor.set("leaderboard_enabled", "1") }
    }

    @Test func memoryTargetsRoundTripAndRefuseDuplicatesAndUnknownRepos() throws {
        let r = try U9Rig()
        let ledger = try Ledger(directory: r.home.url)
        let memory = MemoryExport(ledger: ledger, directory: r.home.url)
        let repo = r.home.url.appendingPathComponent("harbor/checkout").path
        let folder = r.home.url.appendingPathComponent("memory/harbor").path
        _ = try r.editor.addMemoryTarget(repo: repo, folder: folder)
        #expect(try memory.targets() == [MemoryTarget(repo: repo, folder: folder, enabled: false)])
        try refuses(r) { try r.editor.addMemoryTarget(repo: repo, folder: folder + "-other") }
        try refuses(r) { try r.editor.setMemoryTarget(repo: "/missing/repo", enabled: true) }
        try refuses(r) { try r.editor.removeMemoryTarget(repo: "/missing/repo") }
        _ = try r.store.update { $0["external-writer"] = "keep" }
        _ = try r.editor.setMemoryTarget(repo: repo, enabled: true)
        #expect(try memory.targets() == [MemoryTarget(repo: repo, folder: folder, enabled: true)])
        let text = try #require(r.store.read().values["memory_export"])
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        // Slash escaping is not part of the contract.
        #expect(text.replacingOccurrences(of: "\\/", with: "/") ==
                String(decoding: sorted, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/"))
        _ = try r.editor.setMemoryTarget(repo: repo, enabled: false)
        #expect(try memory.targets().first?.enabled == false)
        _ = try r.editor.removeMemoryTarget(repo: repo)
        #expect(try memory.targets().isEmpty)
        #expect(try r.store.read().values["external-writer"] == "keep")
    }

    @Test func memoryTargetPathsUseMemoryExportValidationWithoutWriting() throws {
        let r = try U9Rig()
        for (repo, folder) in [("harbor/checkout", "/memory"), ("/harbor/checkout", "memory"),
                               ("/harbor/../api", "/memory"), ("/harbor/checkout", "/memory/../other")] {
            try refuses(r) { try r.editor.addMemoryTarget(repo: repo, folder: folder) }
        }
    }

    @Test func budgetsRoundTripAndPreserveOtherBudgets() throws {
        let r = try U9Rig()
        _ = try r.editor.setBudget(name: "weekly", scope: "vendor", key: "harbor",
                                  window: "week", dollars: 12.5, hard: true)
        _ = try r.editor.setBudget(name: "free", scope: "root", key: "owner",
                                  window: "run", dollars: 0, hard: false)
        let budgets = try SeatConfig(values: r.store.read().values).budgets
        #expect(budgets.count == 2)
        let weekly = try #require(budgets.first { $0.name == "weekly" })
        #expect(weekly.scope == .vendor && weekly.key == "harbor" && weekly.window == .week)
        #expect(weekly.dollars == 12.5 && weekly.hard)
        let free = try #require(budgets.first { $0.name == "free" })
        #expect(free.scope == .root && free.key == "owner" && free.window == .run)
        #expect(free.dollars == 0 && !free.hard)
        try refuses(r) {
            try r.editor.setBudget(name: "weekly", scope: "vendor", key: "lumen",
                                   window: "lifetime", dollars: 99, hard: false)
        }
        try refuses(r) {
            try r.editor.setBudget(name: "negative", scope: "route", key: "owner->a",
                                   window: "week", dollars: -0.01, hard: true)
        }
        _ = try r.editor.removeBudget(name: "weekly")
        #expect(try SeatConfig(values: r.store.read().values).budgets == [free])
        _ = try r.editor.removeBudget(name: "free")
        #expect(try SeatConfig(values: r.store.read().values).budgets.isEmpty)
    }

    @Test func budgetsUseSeatConfigValidation() throws {
        let r = try U9Rig()
        for (name, scope, key, window) in [("", "vendor", "harbor", "week"),
                                           ("limit", "unknown", "harbor", "week"),
                                           ("limit", "vendor", "", "week"),
                                           ("limit", "vendor", "harbor", "unknown")] {
            try refuses(r) {
                try r.editor.setBudget(name: name, scope: scope, key: key,
                                       window: window, dollars: 1, hard: true)
            }
        }
    }

    @Test func brokerDataReportsSizesTargetsAndInvalidRetention() throws {
        let rig = try U8Rig(); try rig.seed()
        let home = rig.home
        let store = ConfigStore(directory: home.url)
        let repo = home.url.appendingPathComponent("harbor/checkout").path
        let folder = home.url.appendingPathComponent("memory/harbor").path
        _ = try store.update {
            $0["retention_raw_days"] = "7"
            $0["memory_export"] = try! u6aText([["repo": repo, "folder": folder, "enabled": false]])
        }
        try raw(home, "sizes/a", "abc", at: .distantPast)
        try raw(home, "sizes/nested/b", "12345", at: .distantPast)
        for caller in ["owner", "codex"] {
            let data = try success(home, "data", caller: caller)
            #expect(Set(data.keys) == ["retention_days", "database_bytes", "raw_bytes", "total_bytes", "memory_targets"])
            #expect(data["retention_days"] as? Int == 7)
            #expect(data["raw_bytes"] as? Int == 8)
            var database = 0
            for suffix in ["", "-wal", "-shm"] {
                let path = home.url.appendingPathComponent("agencil.sqlite" + suffix).path
                if FileManager.default.fileExists(atPath: path) {
                    database += try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).intValue
                }
            }
            #expect(data["database_bytes"] as? Int == database)
            #expect(data["total_bytes"] as? Int == database + 8)
            #expect(try u6aText(try #require(data["memory_targets"])) ==
                    u6aText([["repo": repo, "folder": folder, "enabled": false]]))
        }
        _ = try store.update { $0["retention_raw_days"] = "invalid" }
        let reply = try home.request(["op": "data", "caller": "codex"])
        #expect(reply["ok"] as? Bool == false && reply["exit"] as? Int == 4)
        #expect(reply["data"] == nil)
        #expect((reply["error"] as? String)?.contains("retention_raw_days is a whole number of days from 1 to 3650") == true)
    }

    @Test func brokerPruneIsOwnerOnlyAndPreservesDurableRecords() throws {
        let rig = try U8Rig(); try rig.seed()
        _ = try ConfigStore(directory: rig.home.url).update { $0["retention_raw_days"] = "7" }
        try rig.sql("INSERT INTO outcomes(id,claim_id,source,certainty,label,created_at) VALUES('u19','f1','owner','final','confirmed','2020-01-01T00:00:00Z');")
        try rig.sql("INSERT INTO evidence(id,claim_id,source,detail,created_at) VALUES('u19','f1','fix-commit','checked','2020-01-01T00:00:00Z');")
        try rig.sql("INSERT INTO verdicts(id,run_id,verdict,minority,independence_flags,created_at) VALUES('u19','s1','PASS','[]','[]','2020-01-01T00:00:00Z');")
        try rig.sql("UPDATE exchanges SET created_at='2020-01-01T00:00:00Z';")
        let before = try durable(rig)
        let old = try raw(rig.home, "old/nested/a", "abc", at: Date().addingTimeInterval(-8 * u13Day))
        let older = try raw(rig.home, "older/b", "12345", at: .distantPast)
        let recent = try raw(rig.home, "recent", "keep", at: Date())
        let denied = try rig.home.request(["op": "prune", "caller": "codex"])
        #expect(denied["ok"] as? Bool == false && denied["exit"] as? Int == 3)
        #expect(denied["data"] == nil)
        #expect((denied["error"] as? String)?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: older.path))
        #expect(try rig.sql("SELECT question,answer FROM exchanges;") == "Inspect boundary|answer\n")
        let report = try success(rig.home, "prune")
        #expect(Set(report.keys) == ["files_deleted", "bytes_freed", "exchanges_cleared"])
        #expect(report["files_deleted"] as? Int == 2)
        #expect(report["bytes_freed"] as? Int == 8)
        #expect(report["exchanges_cleared"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(try Data(contentsOf: recent) == Data("keep".utf8))
        #expect(try rig.sql("SELECT question,answer,state FROM exchanges;") == "||answered\n")
        #expect(try durable(rig) == before)
        let again = try success(rig.home, "prune")
        for key in ["files_deleted", "bytes_freed", "exchanges_cleared"] { #expect(again[key] as? Int == 0) }
    }

    private func refuses(_ r: U9Rig, _ operation: () throws -> ConfigSnapshot) throws {
        let bytes = try r.bytes(), snapshot = try r.store.read()
        do { _ = try operation(); Issue.record("Invalid pane edit accepted") }
        catch let error as SheetProblems {
            #expect(!error.fields.isEmpty && error.fields.values.allSatisfy { !$0.isEmpty })
        }
        #expect(try r.bytes() == bytes)
        #expect(try r.store.read() == snapshot)
    }

    private func success(_ home: BrokerHome, _ op: String, caller: String = "owner") throws -> [String: Any] {
        let reply = try home.request(["op": op, "caller": caller])
        #expect(reply["ok"] as? Bool == true)
        #expect(reply.keys.contains("data_note"))
        return try #require(reply["data"] as? [String: Any])
    }

    @discardableResult
    private func raw(_ home: BrokerHome, _ path: String, _ text: String, at date: Date) throws -> URL {
        let url = home.url.appendingPathComponent("runs/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    private func durable(_ rig: U8Rig) throws -> [String] {
        try ["claims", "evidence", "verdicts", "outcomes"].map {
            try rig.sql("SELECT * FROM \($0) ORDER BY id;")
        }
    }
}
