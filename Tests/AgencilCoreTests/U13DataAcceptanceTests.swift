import Foundation
import Testing
import AgencilCore

struct U13DataAcceptanceTests {
    @Test func retentionDeletesRawAndKeepsDurableRecords() throws {
        let f = try U13Fixture()
        try f.seed(repo: f.repo)
        let before = try f.preserved()
        let old = try f.file("runs/42/nested/maya.txt", at: u13Now.addingTimeInterval(-91 * u13Day))
        let outside = try f.file("logs/keep.txt", at: .distantPast)
        try f.exchange(1, state: "answered", at: u13Now.addingTimeInterval(-91 * u13Day))
        try f.exchange(2, state: "failed", at: u13Now.addingTimeInterval(-91 * u13Day))
        let report = try f.retention.prune(now: u13Now)
        #expect(report.filesDeleted == 1)
        #expect(report.bytesFreed == 10)
        #expect(report.exchangesCleared == 2)
        #expect(!f.exists(old))
        #expect(!f.exists(old.deletingLastPathComponent()))
        #expect(f.exists(f.directory.appendingPathComponent("runs")))
        #expect(try f.bytes(outside) == Data("raw output".utf8))
        #expect(try f.preserved() == before)
        #expect(try f.sql("SELECT question,answer,state,reason,launch_id,chain FROM exchanges ORDER BY seq") == [
            ["", "NULL", "answered", "reason", "launch", "[\"maya\"]"],
            ["", "NULL", "failed", "reason", "launch", "[\"maya\"]"]])
    }

    @Test func exportIsPerSittingEnabledAndIdempotent() throws {
        let f = try U13Fixture()
        try f.seed(42, repo: f.repo)
        try f.seed(43, repo: f.repo, state: "failed")
        try f.exporter.save([f.target])
        let first = try f.exporter.run(now: u13Now)
        #expect(first.written == 2)
        #expect(first.unchanged == 0)
        #expect(first.skipped == 0)
        #expect(try f.exporter.run(now: u13Now).unchanged == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.path).sorted() ==
                ["agencil-sitting-0042.md", "agencil-sitting-0043.md"])
    }

    @Test func defaultRetentionIsNinetyDays() throws {
        let f = try U13Fixture()
        #expect(Retention.defaultDays == 90)
        #expect(try f.retention.days() == 90)
    }

    @Test func configuredRetentionIsUsed() throws {
        let f = try U13Fixture()
        for days in [1, 7, 3650] {
            try f.setting("retention_raw_days", String(days))
            #expect(try f.retention.days() == days)
        }
        try f.setting("retention_raw_days", "7")
        let old = try f.file("runs/old", at: u13Now.addingTimeInterval(-8 * u13Day))
        let recent = try f.file("runs/recent", at: u13Now.addingTimeInterval(-6 * u13Day))
        #expect(try f.retention.prune(now: u13Now).filesDeleted == 1)
        #expect(!f.exists(old))
        #expect(f.exists(recent))
    }

    @Test func invalidRetentionThrowsWithoutDeletingAnything() throws {
        let f = try U13Fixture()
        let old = try f.file("runs/old", at: u13Now.addingTimeInterval(-4000 * u13Day))
        try f.exchange(1, state: "answered", at: u13Now.addingTimeInterval(-4000 * u13Day))
        let rows = try f.sql("SELECT * FROM exchanges")
        for value in ["0", "-1", "3651", "1.5", "abc", "", "90days"] {
            try f.setting("retention_raw_days", value)
            u13Refuses { try f.retention.days() }
            u13Refuses { try f.retention.prune(now: u13Now) }
            #expect(try f.bytes(old) == Data("raw output".utf8))
            #expect(try f.sql("SELECT * FROM exchanges") == rows)
        }
    }

    @Test func cutoffUsesStrictlyOlderModificationTimes() throws {
        let f = try U13Fixture()
        let cutoff = u13Now.addingTimeInterval(-90 * u13Day)
        let inside = try f.file("runs/inside", at: cutoff.addingTimeInterval(1))
        let boundary = try f.file("runs/boundary", at: cutoff)
        let outside = try f.file("runs/outside", at: cutoff.addingTimeInterval(-1))
        for (seq, date) in [(1, cutoff.addingTimeInterval(-1)), (2, cutoff), (3, cutoff.addingTimeInterval(1))] {
            try f.exchange(seq, state: "answered", at: date)
        }
        let report = try f.retention.prune(now: u13Now)
        #expect(report.filesDeleted == 1)
        #expect(report.exchangesCleared == 1)
        #expect(f.exists(inside) && f.exists(boundary) && !f.exists(outside))
        #expect(try f.sql("SELECT question,answer FROM exchanges WHERE seq > 1 ORDER BY seq") ==
                [["question", "answer"], ["question", "answer"]])
    }

    @Test func runsSymlinksAreNeitherFollowedNorDeleted() throws {
        let f = try U13Fixture()
        let destination = try f.file("outside/old", at: .distantPast)
        let link = f.directory.appendingPathComponent("runs/link")
        let directoryLink = f.directory.appendingPathComponent("runs/directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: destination.deletingLastPathComponent())
        #expect(try f.retention.prune(now: u13Now).filesDeleted == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: directoryLink.path) == destination.deletingLastPathComponent().path)
        #expect(try f.bytes(destination) == Data("raw output".utf8))
    }

    @Test func askingExchangesStayUntouched() throws {
        let f = try U13Fixture()
        try f.exchange(1, state: "asking", at: .distantPast)
        let before = try f.sql("SELECT * FROM exchanges")
        #expect(try f.retention.prune(now: u13Now).exchangesCleared == 0)
        #expect(try f.sql("SELECT * FROM exchanges") == before)
    }

    @Test func durableRowCountsAndContentHashesSurvivePruning() throws {
        let f = try U13Fixture()
        try f.seed(repo: f.repo)
        let before = try f.preserved()
        try f.file("runs/old", at: .distantPast)
        _ = try f.retention.prune(now: u13Now)
        #expect(try f.preserved() == before)
    }

    @Test func secondPruneReportsZeros() throws {
        let f = try U13Fixture()
        try f.file("runs/old", at: .distantPast)
        try f.exchange(1, state: "answered", at: .distantPast)
        _ = try f.retention.prune(now: u13Now)
        let second = try f.retention.prune(now: u13Now)
        #expect(second.filesDeleted == 0)
        #expect(second.bytesFreed == 0)
        #expect(second.exchangesCleared == 0)
    }

    @Test func sizeAddsDatabaseSidecarsAndRegularRunFiles() throws {
        let f = try U13Fixture()
        try f.seed(repo: f.repo)
        try f.file("runs/a", text: "abc", at: u13Now)
        try f.file("runs/nested/b", text: "12345", at: u13Now)
        let other = try f.file("logs/ignored", text: "ignore", at: u13Now)
        try FileManager.default.createSymbolicLink(at: f.directory.appendingPathComponent("runs/link"), withDestinationURL: other)
        var database: Int64 = 0
        for name in ["agencil.sqlite", "agencil.sqlite-wal", "agencil.sqlite-shm"] {
            let url = f.directory.appendingPathComponent(name)
            if f.exists(url) {
                database += try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
            }
        }
        let size = try f.retention.size()
        #expect(size.database == database)
        #expect(size.rawOutputs == 8)
        #expect(size.total == database + 8)
    }

    @Test func exportSelectsEnabledFinishedReposAndExactNames() throws {
        let f = try U13Fixture()
        let otherRepo = f.directory.appendingPathComponent("lumen/api").path
        try f.seed(42, repo: f.repo)
        try f.seed(43, repo: f.repo, state: "running")
        try f.seed(44, repo: otherRepo)
        try f.seed(45)
        #expect(try f.exporter.targets().isEmpty)
        #expect(try f.exporter.run(now: u13Now).written == 0)
        #expect(!f.exists(f.folder))
        let disabled = f.directory.appendingPathComponent("memory/lumen")
        try f.exporter.save([MemoryTarget(repo: f.repo, folder: f.folder.path, enabled: false)])
        #expect(try f.exporter.run(now: u13Now).written == 0)
        #expect(!f.exists(f.folder))
        try f.exporter.save([f.target, MemoryTarget(repo: otherRepo, folder: disabled.path, enabled: false)])
        let report = try f.exporter.run(now: u13Now)
        #expect(report.written == 1 && report.skipped == 1)
        #expect(!f.exists(disabled))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.folder.path) == ["agencil-sitting-0042.md"])
        #expect(MemoryExport.fileName(number: 7) == "agencil-sitting-0007.md")
        #expect(MemoryExport.fileName(number: 12345) == "agencil-sitting-12345.md")
        #expect(try f.mode(f.folder) == 0o700)
        #expect(try f.mode(f.output()) == 0o600)
        let text = String(decoding: try f.bytes(f.output()), as: UTF8.self)
        #expect(text.hasPrefix("# Sitting 42: review"))
        for token in ["done", f.stamp(u13Now.addingTimeInterval(-120 * u13Day)), "repair checkout", "lee", "lumen",
                      "shared vendor", "AG-42-1", "maya", "defect", "p1", "src/cart.swift", "17", "confirmed"] {
            #expect(text.contains(token))
        }
    }

    @Test func secondExportKeepsBytesAndModificationTime() throws {
        let f = try U13Fixture()
        try f.seed(repo: f.repo)
        try f.exporter.save([f.target])
        _ = try f.exporter.run(now: u13Now)
        let before = try f.bytes(f.output())
        try FileManager.default.setAttributes([.modificationDate: u13Now.addingTimeInterval(-1234)], ofItemAtPath: f.output().path)
        let time = try f.modified(f.output())
        let report = try f.exporter.run(now: u13Now)
        #expect(report.written == 0 && report.unchanged == 1)
        #expect(try f.bytes(f.output()) == before)
        #expect(try f.modified(f.output()) == time)
        let orphan = try f.file("memory/harbor/agencil-sitting-9999.md", text: "keep orphan", at: u13Now)
        let unrelated = try f.file("memory/harbor/notes.md", text: "keep notes", at: u13Now)
        _ = try f.exporter.run(now: u13Now)
        #expect(try f.bytes(orphan) == Data("keep orphan".utf8))
        #expect(try f.bytes(unrelated) == Data("keep notes".utf8))
    }

    @Test func newOutcomeRewritesOnlyItsSitting() throws {
        let f = try U13Fixture()
        try f.seed(42, repo: f.repo)
        try f.seed(43, repo: f.repo)
        try f.exporter.save([f.target])
        _ = try f.exporter.run(now: u13Now)
        let before = try f.bytes(f.output())
        let other = try f.bytes(f.output(43))
        try FileManager.default.setAttributes([.modificationDate: u13Now], ofItemAtPath: f.output(43).path)
        let time = try f.modified(f.output(43))
        try f.sql("INSERT INTO outcomes(id,claim_id,source,certainty,label,created_at) VALUES('new','AG-42-1','owner','final','refuted',?)",
                  [f.stamp(u13Now.addingTimeInterval(1))])
        let report = try f.exporter.run(now: u13Now.addingTimeInterval(2))
        #expect(report.written == 1 && report.unchanged == 1)
        #expect(try f.bytes(f.output()) != before)
        #expect(String(decoding: try f.bytes(f.output()), as: UTF8.self).contains("refuted"))
        #expect(try f.bytes(f.output(43)) == other)
        #expect(try f.modified(f.output(43)) == time)
    }

    @Test func hostileClaimAndVerdictTextStayInsideLongerFences() throws {
        let f = try U13Fixture()
        let payload = "# injected heading\n``````\n---\n- injected list"
        try f.seed(repo: f.repo, body: payload, verdict: payload)
        try f.exporter.save([f.target])
        _ = try f.exporter.run(now: u13Now)
        let text = String(decoding: try f.bytes(f.output()), as: UTF8.self)
        #expect(u13Fenced(text, contains: payload))
        #expect(text.components(separatedBy: payload).count >= 3)
    }

    @Test func targetSymlinkIsReplacedWithoutTouchingDestination() throws {
        let f = try U13Fixture()
        try f.seed(repo: f.repo)
        try f.exporter.save([f.target])
        let destination = try f.file("outside/keep", text: "untouched", at: u13Now)
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.output(), withDestinationURL: destination)
        #expect(try f.exporter.run(now: u13Now).written == 1)
        #expect(try f.bytes(destination) == Data("untouched".utf8))
        #expect(try f.modified(destination) == u13Now)
        #expect(try FileManager.default.attributesOfItem(atPath: f.output().path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try f.mode(f.output()) == 0o600)
    }

    @Test func saveRefusesRelativeTraversalAndDuplicateRepos() throws {
        let f = try U13Fixture()
        try f.setting("unrelated", "retain exact value")
        try f.exporter.save([f.target])
        let configURL = f.directory.appendingPathComponent("config.json")
        let before = try f.bytes(configURL)
        let invalid = [
            [MemoryTarget(repo: "harbor/checkout", folder: f.folder.path, enabled: true)],
            [MemoryTarget(repo: f.repo, folder: "memory", enabled: true)],
            [MemoryTarget(repo: f.repo + "/../api", folder: f.folder.path, enabled: true)],
            [MemoryTarget(repo: f.repo, folder: f.folder.path + "/../other", enabled: false)],
            [f.target, f.target]
        ]
        for targets in invalid {
            u13Refuses { try f.exporter.save(targets) }
            #expect(try f.bytes(configURL) == before)
        }
        #expect(try f.exporter.targets() == [f.target])
        #expect(try f.store.read().values["unrelated"] == "retain exact value")
        for value in ["invalid", "{}", "[{}]", "[{\"repo\":\"relative\",\"folder\":\"/memory\",\"enabled\":true}]",
                      "[{\"repo\":\"/harbor\",\"folder\":\"/memory/../other\",\"enabled\":false}]"] {
            try f.setting("memory_export", value)
            u13Refuses { try f.exporter.targets() }
            u13Refuses { try f.exporter.run(now: u13Now) }
            #expect(!f.exists(f.folder))
        }
    }
}
