import Foundation
import Testing

@Suite(.serialized) struct U7bTriggersAcceptanceTests {
    @Test func invalidTriggerShapesFailClosedAndNameTheTrigger() throws {
        let r = try U7bRig()
        let bad: [[String: Any]] = [
            ["name": "Bad Name"], ["name": String(repeating: "a", count: 41)],
            ["council": "absent"], ["council": 1], ["repo": "relative"], ["repo": 1],
            ["paths": "src/**"], ["paths": [1]], ["pr_label": 7], ["schedule": "daily"],
            ["schedule": "every 0m"], ["schedule": "every 10001h"], ["schedule": "every 1.5m"],
            ["schedule": "every 1d"], ["debounce_seconds": -1], ["debounce_seconds": 86401],
            ["debounce_seconds": 1.5], ["debounce_seconds": "1"],
            ["quiet_hours": "24:00-07:00"], ["quiet_hours": "22:60-07:00"],
            ["quiet_hours": "night"], ["question": 1], ["change_kind": 1], ["author_vendor": 1]
        ]
        for fields in bad {
            let t = r.trigger(fields)
            try r.configure([t])
            let reply = try r.home.request(["op": "triggers"])
            #expect(reply["ok"] as? Bool == false)
            #expect(reply["exit"] as? Int == 4)
            let error = try #require(reply["error"] as? String)
            #expect(error.hasPrefix("failed: config triggers is invalid: "))
            #expect(error.contains(t["name"] as? String ?? "watch"))
        }
        var noKind = r.trigger(); noKind.removeValue(forKey: "paths")
        for entries in [[noKind], [r.trigger(), r.trigger()]] {
            try r.configure(entries)
            let reply = try r.home.request(["op": "triggers"])
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["error"] as? String)?.contains("watch") == true)
        }
        try r.council.noRuns()
    }

    @Test func triggerContainerMustBeAListAndRequiredFieldsMustExist() throws {
        let r = try U7bRig()
        try r.configure(["watch": r.trigger()])
        #expect(try r.home.request(["op": "triggers"])["ok"] as? Bool == false)
        for key in ["council", "repo"] {
            var entry = r.trigger(); entry.removeValue(forKey: key)
            try r.configure([entry])
            let reply = try r.home.request(["op": "triggers"])
            #expect(reply["ok"] as? Bool == false)
            #expect((reply["error"] as? String)?.contains("watch") == true)
        }
    }

    @Test func validShapesAndListingPreserveConfigOrder() throws {
        let r = try U7bRig()
        let all = r.trigger(["name": "all", "pr_label": "review", "schedule": "every 10000h",
                             "debounce_seconds": 86400, "quiet_hours": "22:00-07:00",
                             "change_kind": "design", "question": "Inspect", "author_vendor": "google"])
        try r.configure([all, r.only("schedule", "every 1m", extra: ["name": "clock"])])
        let data = try r.council.base.data(r.home.request(["op": "triggers"]))
        let rows = try r.rows(data, "triggers")
        #expect(rows.compactMap { $0["name"] as? String } == ["all", "clock"])
        #expect(rows.first?["council"] as? String == "panel")
        #expect(rows.first?["kinds"] as? [String] == ["paths", "pr_label", "schedule"])
        #expect(rows.last?["kinds"] as? [String] == ["schedule"])
        for row in rows {
            #expect(row["last_fired"] is NSNull); #expect(row["last_sitting"] is NSNull)
        }
        let (code, out, _) = try r.home.cli(["triggers"])
        #expect(code == 0); #expect(out.contains("all")); #expect(out.contains("clock"))
        try r.configure([])
        let empty = try r.council.base.data(r.home.request(["op": "triggers"]))
        #expect(try r.rows(empty, "triggers").isEmpty)
        let none = try r.home.cli(["triggers"])
        #expect(none.0 == 0); #expect(none.1.contains("none configured"))
    }

    @Test func pathsBaselineMatchingAndSilentAdvanceCarryExactDiff() throws {
        let r = try U7bRig(); try r.configure([r.trigger()])
        let initial = try r.git(["rev-parse", "HEAD"])
        try r.idle(r.tick()); #expect(try r.value("head") == initial)
        let unrelated = try r.commit("docs/readme", "documentation")
        try r.idle(r.tick()); #expect(try r.value("head") == unrelated)
        let head = try r.commit()
        let id = try r.fired(r.tick(), key: head)
        #expect(try r.value("head") == head)
        #expect(try r.council.sql(".dump briefs").contains("\(unrelated)..\(head)"))
        #expect(try r.council.sql(".dump snapshots").contains(head))
        try r.idle(r.tick())
        #expect(try r.council.sql("SELECT count(*) FROM trigger_fires WHERE outcome='fired';") == "1\n")
        let rows = try r.rows(r.council.base.data(r.home.request(["op": "triggers"])), "triggers")
        #expect(rows.first?["last_sitting"] as? String == id)
        let last = try #require(rows.first?["last_fired"] as? String)
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: last)
        formatter.formatOptions.insert(.withFractionalSeconds)
        #expect((date ?? formatter.date(from: last))?.timeIntervalSince1970 == 1893499200)
    }

    @Test func omittedOptionalFieldsUseDefaultReviewBrief() throws {
        let r = try U7bRig()
        var entry = r.trigger(); entry.removeValue(forKey: "debounce_seconds")
        try r.configure([entry]); try r.idle(r.tick())
        let head = try r.commit(); try r.fired(r.tick(), key: head)
        let briefs = try r.council.sql(".dump briefs")
        #expect(briefs.contains("Review the change since the last sitting."))
        #expect(try r.council.prompt("a").contains("CHANGE KIND: code"))
        _ = try r.commit()
        try r.idle(r.tick("2030-01-01T12:04:59Z"), reason: "debounce")
        let next = try r.git(["rev-parse", "HEAD"])
        try r.fired(r.tick("2030-01-01T12:05:00Z"), key: next)
    }

    @Test func globsMatchWholePathsAndRespectSegmentBoundaries() throws {
        let cases: [(String, String, Bool)] = [
            ("src/*.swift", "src/one.swift", true), ("src/*.swift", "src/deep/one.swift", false),
            ("src/**/one.swift", "src/one.swift", true),
            ("src/**/one.swift", "src/a/b/one.swift", true),
            ("src/?.swift", "src/a.swift", true), ("src/?.swift", "src/ab.swift", false),
            ("src/?.swift", "src/deep/a.swift", false),
            ("one.swift", "src/one.swift", false), ("src/*.swift", "src/one.swift.bak", false)
        ]
        for (glob, path, matches) in cases {
            let r = try U7bRig(); try r.configure([r.trigger(["paths": [glob]])])
            try r.idle(r.tick()); let head = try r.commit(path)
            if matches { try r.fired(r.tick(), key: head) } else { try r.idle(r.tick()) }
            #expect(try r.value("head") == head)
        }
    }

    @Test func missingBaselineAfterHistoryRewriteResetsWithoutFire() throws {
        let r = try U7bRig()
        let orphan = try r.commit("src/lost.swift")
        try r.configure([r.trigger()]); try r.idle(r.tick())
        try r.git(["reset", "--hard", "HEAD~1"])
        try r.git(["reflog", "expire", "--expire=now", "--all"])
        try r.git(["gc", "--prune=now"])
        let check = try BrokerProcess(["-C", r.repo.path, "cat-file", "-e", orphan], home: r.home.url,
                                      executable: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(try check.finish().0 != 0)
        let newHead = try r.commit()
        try r.idle(r.tick()); #expect(try r.value("head") == newHead)
        let next = try r.commit(); try r.fired(r.tick(), key: next)
    }

    @Test func prHeadIsTheKeyAndOldestNumberGoesFirst() throws {
        let r = try U7bRig(); let first = try r.git(["rev-parse", "HEAD"])
        let second = try r.commit("README", "NEW_HEAD")
        try r.configure([r.only("pr_label", "review")])
        try r.prs([r.pr(20, second), r.pr(3, first)])
        try r.fired(r.tick(), key: "pr3@\(first)")
        #expect(try r.council.sql(".dump briefs").contains("pr3@\(first.prefix(12))"))
        #expect(try r.council.sql(".dump snapshots").contains(first))
        try r.fired(r.tick(), key: "pr20@\(second)")
        try r.prs([r.pr(3, first).merging(["updatedAt": "2031-01-01T00:00:00Z",
            "labels": [["name": "agencil-pass"]]]) { _, b in b }, r.pr(20, second)])
        try r.idle(r.tick())
        #expect(try r.value("pr:3") == first)
        try r.prs([r.pr(3, second)])
        try r.fired(r.tick(), key: "pr3@\(second)")
        let cwd = try r.council.text(r.council.control.appendingPathComponent("gh.cwd"))
        #expect(cwd.trimmingCharacters(in: .whitespacesAndNewlines) == (try r.git(["rev-parse", "--show-toplevel"])))
        #expect(try r.council.text(r.council.control.appendingPathComponent("gh.argv")) ==
            "pr\nlist\n--state\nopen\n--label\nreview\n--json\nnumber,headRefOid\n--limit\n100\n")
        #expect(try r.git(["status", "--porcelain"]).isEmpty)
    }

    @Test func prFailuresDoNotConsumeStateAndRecover() throws {
        let r = try U7bRig(); let sha = try r.git(["rev-parse", "HEAD"])
        try r.configure([r.only("pr_label", "review")]); try r.prs([r.pr(1, sha)])
        let before = try r.state()
        for marker in ["gh.fail", "gh.garbage"] {
            try r.council.put(marker); try r.idle(r.tick(), reason: "gh_unavailable")
            #expect(try r.state() == before)
            try FileManager.default.removeItem(at: r.council.control.appendingPathComponent(marker))
        }
        for garbage in ["{}", "[{\"number\":1}]", "[{\"number\":\"one\",\"headRefOid\":\"x\"}]"] {
            try r.council.put("gh.json", garbage)
            try r.idle(r.tick(), reason: "gh_unavailable"); #expect(try r.state() == before)
        }
        let gh = r.council.base.bin.appendingPathComponent("gh")
        try FileManager.default.removeItem(at: gh)
        // Executable discovery succeeds but launch gets ENOENT. Never fall through to a real gh.
        try "#!/nonexistent/u7b-interpreter\n".write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        try r.idle(r.tick(), reason: "gh_unavailable"); #expect(try r.state() == before)
        try FileManager.default.removeItem(at: gh)
        try Data(contentsOf: brokerFixture("u7b-gh.sh")).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let absent = String(repeating: "f", count: 40)
        try r.prs([r.pr(1, absent)])
        try r.idle(r.tick(), reason: "commit_missing"); #expect(try r.state() == before)
        try r.prs([r.pr(1, sha)]); try r.fired(r.tick(), key: "pr1@\(sha)")
    }

    @Test func scheduleBaselinesAndConsumesOnlyWhenIntervalElapses() throws {
        let r = try U7bRig(); try r.configure([r.only("schedule", "every 1h")])
        try r.idle(r.tick()); try r.idle(r.tick("2030-01-01T12:59:59Z"))
        let epoch = Int(try #require(ISO8601DateFormatter().date(from: "2030-01-01T13:00:00Z")).timeIntervalSince1970)
        try r.fired(r.tick("2030-01-01T13:00:00Z"), key: "schedule@\(epoch)")
        #expect(try Double(r.value("schedule")) == Double(epoch))
        #expect(try r.council.sql(".dump briefs").contains("HEAD"))
        try r.idle(r.tick("2030-01-01T13:59:59Z"))
    }

    @Test func debounceAccumulatesDiffUntilExactBoundary() throws {
        let r = try U7bRig(); try r.configure([r.trigger(["debounce_seconds": 60])])
        try r.idle(r.tick()); let a = try r.commit(); try r.fired(r.tick(), key: a)
        _ = try r.commit("src/second.swift")
        try r.idle(r.tick("2030-01-01T12:00:59Z"), reason: "debounce")
        #expect(try r.value("head") == a)
        let b = try r.commit("src/third.swift")
        try r.fired(r.tick("2030-01-01T12:01:00Z"), key: b)
        #expect(try r.council.sql(".dump briefs").contains("\(a)..\(b)"))
    }

    @Test func quietHoursDeferAcrossMidnightWithoutConsuming() throws {
        for (quiet, baseline, deferred, release) in [
            ("12:00-13:00", "2030-01-01T11:59:00Z", "2030-01-01T12:00:00Z", "2030-01-01T13:00:00Z"),
            ("22:00-07:00", "2030-01-01T21:59:00Z", "2030-01-02T01:00:00Z", "2030-01-02T07:00:00Z")
        ] {
            let r = try U7bRig(); try r.configure([r.trigger(["quiet_hours": quiet])])
            try r.idle(r.tick(baseline)); let before = try r.state()
            if quiet == "22:00-07:00" {
                _ = try r.commit()
                try r.idle(r.tick("2030-01-01T22:00:00Z"), reason: "quiet_hours")
                #expect(try r.state() == before)
            }
            _ = try r.commit(); try r.idle(r.tick(deferred), reason: "quiet_hours")
            #expect(try r.state() == before)
            let head = try r.commit("src/accumulated.swift")
            try r.fired(r.tick(release), key: head)
        }
    }

    @Test func runningSittingDefersBeforeQuietHoursAndDebounce() throws {
        let r = try U7bRig(); try r.configure([r.trigger(["debounce_seconds": 60, "quiet_hours": "13:00-14:00"])])
        try r.council.put("a.blind.hold"); try r.idle(r.tick())
        let a = try r.commit(); let id = try r.fired(r.tick(), key: a, wait: false)
        try brokerPoll { !r.council.observations("a").isEmpty }
        let b = try r.commit()
        try r.idle(r.tick("2030-01-01T13:00:00Z"), reason: "running")
        #expect(try r.value("head") == a)
        try r.council.put("release"); _ = try r.council.cli(["result", id, "--wait", "15"], exit: 0)
        try r.fired(r.tick("2030-01-01T14:00:00Z"), key: b)
    }

    @Test func noRouteRecordsRefusalAndRetriesSameCandidateAfterPermissionChanges() throws {
        let r = try U7bRig(); try r.configure([r.trigger()], allowed: false)
        try r.idle(r.tick()); let before = try r.state(); let head = try r.commit()
        let reply = try r.tick(); #expect(try r.rows(reply, "fired").isEmpty)
        #expect(try r.state() == before)
        #expect(try r.council.sql("SELECT outcome,key FROM trigger_fires;") == "refused|\(head)\n")
        #expect(try r.council.sql("SELECT count(*) FROM requests WHERE outcome='refused';") == "1\n")
        try r.council.noRuns()
        #expect(try r.rows(r.tick("2030-01-01T12:00:30Z"), "fired").isEmpty)
        #expect(try r.state() == before)
        #expect(try r.council.sql("SELECT count(*) FROM trigger_fires WHERE outcome='refused';") == "2\n")
        try r.configure([r.trigger()]); try r.fired(r.tick("2030-01-01T12:01:00Z"), key: head)
    }

    @Test func acceptedStateSurvivesRestartWithoutDuplicateFire() throws {
        let r = try U7bRig(); try r.configure([r.trigger()]); try r.idle(r.tick())
        let head = try r.commit(); try r.fired(r.tick(), key: head)
        let before = try r.state(); try r.restart()
        #expect(try r.state() == before); try r.idle(r.tick())
        #expect(try r.council.sql("SELECT count(*) FROM trigger_fires WHERE outcome='fired';") == "1\n")
        let next = try r.commit(); try r.fired(r.tick(), key: next)
    }

    @Test func kindsHavePriorityAndTriggersAreJudgedIndependently() throws {
        let r = try U7bRig(); let first = try r.git(["rev-parse", "HEAD"])
        try r.configure([r.trigger(["pr_label": "review", "schedule": "every 1m"]),
            r.only("schedule", "every 1m", extra: ["name": "clock", "quiet_hours": "12:00-13:00"])])
        try r.idle(r.tick()); let head = try r.commit(); try r.prs([r.pr(1, first)])
        let reply = try r.tick("2030-01-01T12:01:00Z")
        try r.fired(reply, key: head)
        #expect(try r.rows(reply, "deferred").first?["trigger"] as? String == "clock")
        #expect(try r.rows(reply, "deferred").first?["reason"] as? String == "quiet_hours")
        try r.fired(r.tick("2030-01-01T12:01:01Z"), key: "pr1@\(first)")
    }

    @Test func wakeCommitMustBeFullHexAndResolveToCommitAndPinsSnapshot() throws {
        let r = try U7bRig(); let sha = try r.git(["rev-parse", "HEAD"])
        let blob = try r.git(["rev-parse", "HEAD:README"])
        for commit in ["HEAD", String(sha.prefix(12)), String(repeating: "z", count: 40),
                       String(repeating: "f", count: 40), blob] {
            let reply = try r.home.request(["op": "wake", "caller": "owner", "council": "panel",
                "change_kind": "code", "question": "Inspect", "diff": "HEAD", "repo": r.repo.path,
                "commit": commit])
            #expect(reply["ok"] as? Bool == false); #expect(reply["exit"] as? Int == 64)
        }
        try r.council.noRuns()
        _ = try r.commit("README", "LATER_HEAD")
        let reply = try r.council.base.data(r.home.request(["op": "wake", "caller": "owner",
            "council": "panel", "change_kind": "code", "question": "Inspect", "diff": "HEAD",
            "repo": r.repo.path, "commit": sha, "wait_seconds": 15]))
        #expect(try r.council.verdict(reply)["verdict"] as? String == "PASS")
        #expect(try r.council.sql(".dump snapshots").contains(sha))
        for file in r.council.observations(suffix: "readme") {
            #expect(try r.council.text(file) == "COMMITTED_MARKER")
        }
        #expect(!r.council.observations(suffix: "readme").isEmpty)
    }
}
