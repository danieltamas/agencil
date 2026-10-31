import Foundation
import Testing
import AgencilCore

@Suite("U14 leaderboard acceptance")
struct U14LeaderboardAcceptanceTests {
    @Test func previewAllowlistAndPrivacy() throws {
        let f = try U14Fixture(); try f.seed()
        let github = U14GitHub(), publisher = f.publisher(github)
        let bytes = try publisher.preview(now: u14Now, golden: [:])
        let text = String(decoding: bytes, as: UTF8.self), root = try u14Object(bytes)
        #expect(Set(root.keys) == ["schema", "generated_at", "window", "outcomes_total", "min_n", "cells"])
        for secret in ["harbor/checkout", "src/private.swift", "private claim text", "private prompt", "maya", "lee"] {
            #expect(!text.contains(secret))
        }
        #expect(github.calls.isEmpty)
        #expect(bytes == (try LeaderboardExport.canonicalJSON(f.build())))
        try LeaderboardValidator.validate(bytes, aliasesOnMain: [])
    }

    @Test func unknownLocalModelIsAbsent() throws {
        let f = try U14Fixture(models: ["client-project"]); try f.seed()
        #expect(try f.build().cells.isEmpty)
    }

    @Test func aliasesRequireApprovalOnMain() throws {
        let f = try U14Fixture(models: ["client-project"]); try f.seed()
        #expect(try f.build(aliases: ["client-project": "harbor-model"]).cells.isEmpty)
        #expect(try f.build(aliases: ["client-project": "harbor-model"], approved: ["harbor-model"]).cells.first?.model == "harbor-model")
    }

    @Test func minimumBoundary() throws {
        let f = try U14Fixture(); try f.seed(19)
        #expect(try f.build().cells.isEmpty)
        let g = try U14Fixture(); try g.seed(20)
        #expect(try g.build().cells.first?.n == 20)
    }

    @Test func minimumIsClampedToTen() throws {
        let f = try U14Fixture(); try f.seed(9, confirmed: 9)
        #expect(try f.build(minN: 1).minN == 10)
        #expect(try f.build(minN: 1).cells.isEmpty)
        let g = try U14Fixture(); try g.seed(10)
        #expect(try g.build(minN: 1).cells.count == 1)
    }

    @Test func aggregateRatesWilsonDurationCostAndWindow() throws {
        let f = try U14Fixture(); try f.seed(unresolved: 3)
        let data = try f.build(), cell = try #require(data.cells.first)
        #expect(cell.n == 20 && cell.confirmed == 10 && cell.refuted == 10 && cell.unresolved == 3)
        #expect(cell.confirmedShare == 0.5)
        #expect(cell.confirmedShareCI == [0.30, 0.70])
        #expect(cell.coverage == 1 && cell.coverageCI == [0.72, 1])
        #expect(cell.medianSeconds == 10 && cell.costPerConfirmedUSD == 0.2)
        #expect(data.outcomesTotal == 20)
        #expect(data.from == "2024-12-01T00:00:00Z")
        #expect(data.to == "2025-01-01T00:00:00Z" && data.generatedAt == data.to)
    }

    @Test func noCoverageOrGoldenDenominatorOmitsKeys() throws {
        let f = try U14Fixture(); try f.seed(confirmed: 0)
        let data = try f.build(), cell = try #require(data.cells.first)
        #expect(cell.coverage == nil && cell.coverageCI == nil)
        #expect(cell.goldenRecall == nil && cell.goldenN == 0 && cell.costPerConfirmedUSD == nil)
        let root = try u14Object(LeaderboardExport.canonicalJSON(data))
        let json = try #require((root["cells"] as? [[String: Any]])?.first)
        for key in ["coverage", "coverage_ci", "golden_recall", "cost_per_confirmed_usd", "recall"] {
            #expect(json[key] == nil)
        }
    }

    @Test func failedAnswersExcludedFromCoverage() throws {
        let f = try U14Fixture(); try f.seed(exit: 1)
        #expect(try f.build().cells.first?.coverage == nil)
    }

    @Test func explicitZeroGoldenSampleOmitsRecall() throws {
        let f = try U14Fixture(); try f.seed()
        let data = try f.build(golden: ["maya": GoldenScore.score([])])
        let cell = try #require(data.cells.first)
        #expect(cell.goldenN == 0 && cell.goldenRecall == nil)
        let root = try u14Object(LeaderboardExport.canonicalJSON(data))
        #expect(try #require((root["cells"] as? [[String: Any]])?.first)["golden_recall"] == nil)
    }

    @Test func sameModelHarnessMergesAndGoldenSums() throws {
        let f = try U14Fixture(models: ["gpt-5.x-codex", "gpt-5.x-codex"])
        try f.seed(10, confirmed: 6, seconds: 10)
        try f.seed(10, confirmed: 4, sitting: 42, seat: "jonas", seconds: 30, cost: 4)
        func score(_ known: Int, _ found: Int) -> GoldenScore {
            GoldenScore.score([GoldenResult(brief: "auth", known: known, found: found,
                                            raisedBlocker: false, confirmedClaims: 0, refutedClaims: 0)])
        }
        let data = try f.build(golden: ["maya": score(4, 3), "jonas": score(6, 2)])
        let cell = try #require(data.cells.first)
        #expect(data.cells.count == 1 && cell.n == 20)
        #expect(cell.goldenN == 10 && cell.goldenRecall == 0.5)
        #expect(cell.medianSeconds == 20 && cell.costPerConfirmedUSD == 0.6)
    }

    @Test(arguments: ["auth", "schema", "ui", "refactor", "infra", "other", "unknown", ""])
    func changeKindFromBrief(_ kind: String) throws {
        let f = try U14Fixture(); try f.seed(kind: kind)
        #expect(try f.build().cells.first?.changeKind == (["unknown", ""].contains(kind) ? "other" : kind))
    }

    @Test func removedSeatSkipped() throws {
        let f = try U14Fixture(); try f.seed()
        _ = try f.store.update { $0["seats"] = "[]" }
        #expect(try f.build().cells.isEmpty)
    }

    @Test func repeatedClaimsCreditEachSeatOncePerFinding() throws {
        let f = try U14Fixture(models: ["gpt-5.x-codex", "qwen3:32b"])
        try f.seed(); try f.seed(sitting: 41, seat: "jonas")
        try f.sql("INSERT INTO claims(id,run_id,seat_run_id,body,kind,severity,file,line,created_at) SELECT 'duplicate',run_id,seat_run_id,body,kind,severity,file,line,created_at FROM claims WHERE id='41maya0'")
        let data = try f.build()
        #expect(data.cells.count == 2 && data.outcomesTotal == 20)
        for cell in data.cells {
            #expect(cell.n == 20 && cell.confirmed == 10 && cell.refuted == 10)
            #expect(cell.coverage == 1)
        }
    }

    @Test func pendingCountsNowhereAndDoesNotExtendWindow() throws {
        let f = try U14Fixture(); try f.seed(pendingClaimAt: "2024-12-31T00:00:00Z")
        let data = try f.build(), cell = try #require(data.cells.first)
        #expect(cell.n == 20 && cell.unresolved == 0 && data.outcomesTotal == 20)
        #expect(cell.confirmedShare == 0.5 && cell.coverage == 1)
        #expect(data.from == "2024-12-01T00:00:00Z")
    }

    @Test func coverageIncludesFindingsOtherSeatsRaisedInValidSittings() throws {
        let f = try U14Fixture(models: ["gpt-5.x-codex", "qwen3:32b"])
        try f.seed(); try f.seed(20, confirmed: 20, sitting: 41, seat: "jonas", lineOffset: 1000)
        let cell = try #require(f.build().cells.first { $0.model == "gpt-5.x-codex" })
        #expect(cell.coverage == 1.0 / 3.0)
        #expect(cell.coverageCI == [0.19, 0.51])
    }

    @Test func modelHarnessAndChangeKindDefineSeparateCells() throws {
        let f = try U14Fixture(models: ["gpt-5.x-codex", "gpt-5.x-codex"])
        try f.seed(); try f.seed(sitting: 42, seat: "jonas", kind: "ui")
        #expect(try Set(f.build().cells.map(\.changeKind)) == ["auth", "ui"])
        let seats = try #require(try f.store.read().values["seats"])
        let objects = try #require(JSONSerialization.jsonObject(with: Data(seats.utf8)) as? [[String: String]])
        var changed = objects; changed[1]["harness"] = "opencode"
        let encoded = String(decoding: try u14JSON(changed), as: UTF8.self)
        _ = try f.store.update { $0["seats"] = encoded }
        #expect(try Set(f.build().cells.map(\.harness)) == ["codex", "opencode"])
    }

    @Test func missingChangeKindBecomesOther() throws {
        let f = try U14Fixture(); try f.seed(brief: "harbor/checkout")
        #expect(try f.build().cells.first?.changeKind == "other")
    }

    @Test func publicModelPatternAndCatalog() throws {
        #expect(PublicModels.pattern == "^[a-z0-9][a-z0-9._:-]{0,63}$")
        #expect(PublicModels.isPublic("gpt-5.x-codex"))
        #expect(PublicModels.isPublic("qwen3:32b"))
        #expect(!PublicModels.isPublic("client-project"))
    }

    @Test func canonicalBytesAreStableASCIIIndentedAndTerminated() throws {
        let f = try U14Fixture(); try f.seed()
        let a = try LeaderboardExport.canonicalJSON(f.build())
        #expect(a == (try LeaderboardExport.canonicalJSON(f.build())))
        #expect(a.last == 10 && a.allSatisfy { $0 < 128 })
        #expect(String(decoding: a, as: UTF8.self).contains("\n  \"cells\""))
    }

    @Test(arguments: ["valid", "unknown-key", "bad-model", "low-n", "bad-sum", "bad-kind"])
    func sharedValidatorFixtures(_ name: String) throws {
        let bytes = try Data(contentsOf: u14Root.appendingPathComponent("Tests/Fixtures/leaderboard/\(name).json"))
        if name == "valid" { try LeaderboardValidator.validate(bytes, aliasesOnMain: []) }
        else { u14Refuses { try LeaderboardValidator.validate(bytes, aliasesOnMain: []) } }
    }

    @Test func validatorRejectsEveryStructuralAndNumericViolation() throws {
        let valid = try u14Object(Data(contentsOf: u14Root.appendingPathComponent("Tests/Fixtures/leaderboard/valid.json")))
        for key in valid.keys {
            var bad = valid; bad.removeValue(forKey: key)
            u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
        }
        let mutations: [(String, Any)] = [("harness", "unknown"), ("n", -1), ("confirmed", 1.5),
            ("refuted", true), ("unresolved", -1), ("golden_n", -1), ("confirmed_share", 1.1),
            ("coverage", -0.1), ("golden_recall", 2), ("confirmed_share_ci", [0.8, 0.2]),
            ("coverage_ci", [0, 1, 1]), ("model", "harbor/model"), ("extra", "private")]
        for (key, value) in mutations {
            var bad = valid, cells = try #require(valid["cells"] as? [[String: Any]])
            cells[0][key] = value; bad["cells"] = cells
            u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
        }
        for (key, value) in [("schema", 2), ("min_n", 9), ("outcomes_total", -1)] {
            var bad = valid; bad[key] = value
            u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
        }
        var bad = valid; bad["window"] = ["from": "private/path", "to": "2025-01-01T00:00:00Z", "extra": "x"]
        u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
    }

    @Test func validatorRequiresCellAndWindowKeysAndSafeStrings() throws {
        let valid = try u14Object(Data(contentsOf: u14Root.appendingPathComponent("Tests/Fixtures/leaderboard/valid.json")))
        let cell = try #require((valid["cells"] as? [[String: Any]])?.first)
        for key in ["model", "harness", "change_kind", "n", "confirmed", "refuted", "unresolved",
                    "confirmed_share", "confirmed_share_ci", "golden_n"] {
            var bad = valid, changed = cell; changed.removeValue(forKey: key); bad["cells"] = [changed]
            u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
        }
        for key in ["from", "to"] {
            var bad = valid, window = try #require(valid["window"] as? [String: String])
            window.removeValue(forKey: key); bad["window"] = window
            u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
        }
        for text in ["harbor/checkout", "harbor\\checkout", "private\nvalue", "private\u{00e9}"] {
            var bad = valid; bad["generated_at"] = text
            u14Refuses { try LeaderboardValidator.validate(u14JSON(bad), aliasesOnMain: []) }
        }
        var alias = valid, changed = cell; changed["model"] = "harbor-model"; alias["cells"] = [changed]
        u14Refuses { try LeaderboardValidator.validate(u14JSON(alias), aliasesOnMain: []) }
        try LeaderboardValidator.validate(u14JSON(alias), aliasesOnMain: ["harbor-model"])
    }

    @Test func putCarriesOnlyBranchMessageContentAndFreshSHA() throws {
        let f = try U14Fixture(); try f.seed()
        let github = U14GitHub(try [u14Response(200, ["sha": "first"]), u14Response(200),
                                    u14Response(200, ["sha": "second"]), u14Response(201)])
        let p = f.publisher(github), preview = try p.preview(now: u14Now, golden: [:])
        try p.press(now: u14Now, golden: [:]); try p.press(now: u14Now, golden: [:])
        #expect(github.calls.map(\.method) == ["GET", "PUT", "DISPATCH", "GET", "PUT", "DISPATCH"])
        for (index, sha) in [(1, "first"), (4, "second")] {
            let call = github.calls[index], body = try u14Object(#require(call.body))
            #expect(call.path == "repos/danieltamas/agencil/contents/data.json")
            #expect(Set(body.keys) == ["branch", "message", "content", "sha"])
            #expect(body["branch"] as? String == "leaderboard" && body["sha"] as? String == sha)
            #expect(!(try #require(body["message"] as? String)).isEmpty)
            #expect(Data(base64Encoded: try #require(body["content"] as? String)) == preview)
        }
        #expect(github.calls[0].path == "repos/danieltamas/agencil/contents/data.json?ref=leaderboard")
        #expect(github.calls[2].path == "leaderboard.yml@main")
    }

    @Test func missingFileOmitsSHA() throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(404), u14Response(201)])
        try f.publisher(github).press(now: u14Now, golden: [:])
        let body = try u14Object(#require(github.calls[1].body))
        #expect(Set(body.keys) == ["branch", "message", "content"])
    }

    @Test func customRepositoryAndMinimumSettings() throws {
        let f = try U14Fixture(settings: ["leaderboard_repo": "harbor/checkout", "leaderboard_min_n": "1"])
        try f.seed(10)
        let github = U14GitHub(try [u14Response(404), u14Response(201)])
        let p = f.publisher(github)
        let preview = try u14Object(p.preview(now: u14Now, golden: [:]))
        #expect(preview["min_n"] as? Int == 10)
        try p.press(now: u14Now, golden: [:])
        #expect(github.calls[0].path == "repos/harbor/checkout/contents/data.json?ref=leaderboard")
        #expect(github.calls[1].path == "repos/harbor/checkout/contents/data.json")
    }

    @Test(arguments: [403, 500]) func failedGETSendsNoPUT(_ status: Int) throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(status)])
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.map(\.method) == ["GET"])
    }

    @Test func malformedGETBodyFailsClosed() throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(200)])
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.count == 1)
    }

    @Test(arguments: [409, 422]) func conflictRereadsAndRetriesOnce(_ status: Int) throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(200, ["sha": "old"]),
            u14Response(status), u14Response(200, ["sha": "new"]), u14Response(200)])
        try f.publisher(github).press(now: u14Now, golden: [:])
        #expect(github.calls.map(\.method) == ["GET", "PUT", "GET", "PUT", "DISPATCH"])
        #expect(try u14Object(#require(github.calls[3].body))["sha"] as? String == "new")
    }

    @Test(arguments: [409, 422, 500]) func secondFailureNeverDispatches(_ status: Int) throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(404), u14Response(409),
            u14Response(404), u14Response(status)])
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.map(\.method) == ["GET", "PUT", "GET", "PUT"])
        #expect(try f.store.read().values["leaderboard_enabled"] != "1")
    }

    @Test(arguments: [400, 403, 500]) func nonConflictPUTFailureNeverDispatches(_ status: Int) throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(404), u14Response(status)])
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.count == 2)
    }

    @Test(arguments: ["", "0", "true", "2"]) func scheduledOffBeforeManualPress(_ enabled: String) throws {
        let f = try U14Fixture(settings: ["leaderboard_enabled": enabled]), github = U14GitHub()
        #expect(try !f.publisher(github).publishScheduled(now: u14Now, golden: [:]))
        #expect(github.calls.isEmpty)
    }

    @Test func manualPressEnablesScheduledAndRereadsConfig() throws {
        let f = try U14Fixture(), github = U14GitHub(try [u14Response(404), u14Response(201), u14Response(404), u14Response(200)])
        let p = f.publisher(github)
        #expect(try !p.publishScheduled(now: u14Now, golden: [:]))
        try p.press(now: u14Now, golden: [:])
        #expect(try f.store.read().values["leaderboard_enabled"] == "1")
        #expect(try p.publishScheduled(now: u14Now, golden: [:]))
        _ = try f.store.update { $0["leaderboard_enabled"] = "0" }
        #expect(try !p.publishScheduled(now: u14Now, golden: [:]))
        #expect(github.calls.count == 6)
    }

    @Test(arguments: ["leaderboard_repo", "leaderboard_min_n", "leaderboard_aliases"])
    func malformedSettingsFailBeforeAnyRequest(_ key: String) throws {
        let malformed = ["leaderboard_repo": "bad repo", "leaderboard_min_n": "bad/value", "leaderboard_aliases": "bad/value"]
        let f = try U14Fixture(settings: [key: malformed[key]!]), github = U14GitHub()
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.isEmpty)
    }

    @Test(arguments: ["20.5", "twenty", "", "[]"])
    func minimumMustBeWholeNumber(_ value: String) throws {
        let f = try U14Fixture(settings: ["leaderboard_min_n": value]), github = U14GitHub()
        u14Refuses { try f.publisher(github).preview(now: u14Now, golden: [:]) }
        #expect(github.calls.isEmpty)
    }

    @Test(arguments: ["harbor", "harbor/checkout/extra", "harbor/", "/checkout", "harbor/check out"])
    func repositorySettingMustBeOwnerAndName(_ value: String) throws {
        let f = try U14Fixture(settings: ["leaderboard_repo": value]), github = U14GitHub()
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.isEmpty)
    }

    @Test(arguments: ["[]", "{\"client-project\":4}", "{\"client-project\":\"harbor/model\"}"])
    func aliasesMustBeObjectWithPatternValues(_ value: String) throws {
        let f = try U14Fixture(settings: ["leaderboard_aliases": value]), github = U14GitHub()
        u14Refuses { try f.publisher(github).press(now: u14Now, golden: [:]) }
        #expect(github.calls.isEmpty)
    }
}
