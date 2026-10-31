import Foundation

/// What a trigger would wake the council with, and the state that moves on once the wake is accepted.
struct Candidate {
    let key: String
    let diff: String
    let commit: String?
    let consume: [(key: String, value: String)]
}

/// How one trigger fared in an evaluation.
enum Evaluation {
    case fired([String: Any])
    case deferred(String)
    case nothing
}

/// Evaluation of triggers (docs/U7-SPEC.md "Triggers (U7b)"): candidates, deferrals, and the wake.
extension Broker {
    private static let sha = #"\A[0-9a-f]{40}\z"#

    /// A stored time in whole seconds; anything outside the years 1970 to 3000 is a corrupt row.
    static func epoch(_ text: String) -> Int? {
        guard let value = Int(text), (0...32_503_680_000).contains(value) else { return nil }
        return value
    }

    func triggersOp() throws -> [String: Any] {
        let config = try SeatConfig(values: try ConfigStore(directory: directory).read().values)
        let rows = try config.triggers.map { trigger -> [String: Any] in
            let last = try triggerRows.last(trigger.name)
            return ["name": trigger.name, "council": trigger.council, "kinds": trigger.kinds,
                    "last_fired": last?.at ?? NSNull(), "last_sitting": last?.sitting ?? NSNull()]
        }
        return ["ok": true, "data": ["triggers": rows], "data_note": Self.note]
    }

    /// One serialised pass over every trigger at `now`.
    func tick(now: Date) throws -> [String: Any] {
        let config = try SeatConfig(values: try ConfigStore(directory: directory).read().values)
        return try triggerLock.withLock {
            var fired: [[String: Any]] = [], deferred: [[String: Any]] = []
            for trigger in config.triggers {
                // One trigger's failure never keeps the others from being judged.
                switch (try? evaluate(trigger, now: now)) ?? .deferred("error") {
                case .fired(let row): fired.append(row)
                case .deferred(let reason): deferred.append(["trigger": trigger.name, "reason": reason])
                case .nothing: break
                }
            }
            return ["ok": true, "data": ["fired": fired, "deferred": deferred], "data_note": Self.note]
        }
    }

    private func evaluate(_ trigger: Trigger, now: Date) throws -> Evaluation {
        var candidate: Candidate?
        for kind in trigger.kinds where candidate == nil {
            let found: (Candidate?, String?)
            switch kind {
            case "paths": found = try pathsCandidate(trigger)
            case "pr_label": found = try pullRequestCandidate(trigger)
            default: found = try scheduleCandidate(trigger, now: now)
            }
            // A source that cannot be read stops the trigger: a later kind never fires in its place.
            if let problem = found.1 { return .deferred(problem) }
            candidate = found.0
        }
        guard let candidate else { return .nothing }
        if let last = try triggerRows.last(trigger.name), try sittingRows.record(last.sitting)?.state == "running" { return .deferred("running") }
        var local = tm(), seconds = time_t(now.timeIntervalSince1970)
        localtime_r(&seconds, &local)
        if trigger.isQuiet(minute: Int(local.tm_hour) * 60 + Int(local.tm_min)) { return .deferred("quiet_hours") }
        if let raw = try triggerRows.state(trigger.name, "last_fire") {
            guard let last = Self.epoch(raw) else { return .deferred("state_invalid") }
            if Int(now.timeIntervalSince1970) - last < trigger.debounceSeconds { return .deferred("debounce") }
        }
        return try fire(trigger, candidate, now: now)
    }

    private func fire(_ trigger: Trigger, _ candidate: Candidate, now: Date) throws -> Evaluation {
        var request: [String: Any] = ["op": "wake", "caller": "trigger", "council": trigger.council, "change_kind": trigger.changeKind,
                                      "question": trigger.question, "repo": trigger.repo, "diff": candidate.diff, "wait_seconds": 0]
        if let commit = candidate.commit { request["commit"] = commit }
        if let author = trigger.authorVendor { request["author_vendor"] = author }
        let me = getpid()
        let before = try triggerRows.claim(trigger.name, at: now, consume: candidate.consume)
        let reply = wake(request, peer: me, peerStart: ProcessTable.startTime(of: me))
        guard reply["ok"] as? Bool == true, let sitting = (reply["data"] as? [String: Any])?["sitting"] as? String else {
            let exit = reply["exit"] as? Int ?? 70
            try triggerRows.release(trigger.name, before, key: candidate.key, outcome: exit == 3 ? "refused" : "failed",
                                    detail: reply["error"] as? String ?? "the wake failed", at: now)
            return .nothing
        }
        try triggerRows.fired(trigger.name, key: candidate.key, sitting: sitting, at: now)
        return .fired(["trigger": trigger.name, "council": trigger.council, "key": candidate.key, "sitting": sitting])
    }

    // MARK: paths

    private func pathsCandidate(_ trigger: Trigger) throws -> (Candidate?, String?) {
        guard RepoCopy.isRepository(trigger.repo), let head = RepoCopy.output(["-C", trigger.repo, "rev-parse", "--verify", "HEAD^{commit}"]),
              head.range(of: Self.sha, options: .regularExpression) != nil else { return (nil, "repo_unavailable") }
        guard let base = try triggerRows.state(trigger.name, "head") else {
            try triggerRows.set(trigger.name, [("head", head)])
            return (nil, nil)
        }
        guard base.range(of: Self.sha, options: .regularExpression) != nil else { return (nil, "state_invalid") }
        if base == head { return (nil, nil) }
        // Only a confirmed absence (exit 1) resets the baseline; a timeout or a git failure keeps it.
        switch RepoCopy.status(["-C", trigger.repo, "cat-file", "-e", base]) {
        case 0: break
        case 1:
            try triggerRows.set(trigger.name, [("head", head)])
            return (nil, nil)
        default: return (nil, "git_unavailable")
        }
        guard let listing = RepoCopy.data(["-C", trigger.repo, "diff", "--name-only", "-z", "--no-ext-diff", base, head]) else {
            return (nil, "git_unavailable")
        }
        let matchers = (trigger.paths ?? []).compactMap(Glob.init)
        let names = String(decoding: listing, as: UTF8.self).split(separator: "\0").map(String.init)
        guard names.contains(where: { name in matchers.contains { $0.matches(name) } }) else {
            try triggerRows.set(trigger.name, [("head", head)])
            return (nil, nil)
        }
        return (Candidate(key: head, diff: "\(base)..\(head)", commit: head, consume: [("head", head)]), nil)
    }

    // MARK: pull requests

    private func pullRequestCandidate(_ trigger: Trigger) throws -> (Candidate?, String?) {
        guard let label = trigger.prLabel else { return (nil, nil) }
        guard let listed = pullRequests(label: label, repo: trigger.repo) else { return (nil, "gh_unavailable") }
        for pr in listed.sorted(by: { $0.number < $1.number }) {
            if try triggerRows.state(trigger.name, "pr:\(pr.number)") == pr.head { continue }
            guard RepoCopy.output(["-C", trigger.repo, "cat-file", "-e", pr.head + "^{commit}"]) != nil else { return (nil, "commit_missing") }
            return (Candidate(key: "pr\(pr.number)@\(pr.head)", diff: "pr\(pr.number)@\(pr.head.prefix(12))", commit: pr.head,
                              consume: [("pr:\(pr.number)", pr.head)]), nil)
        }
        return (nil, nil)
    }

    /// `gh pr list` for the label, or nil when gh is missing, fails, times out or answers with anything else than the expected JSON.
    /// gh runs in its own process group with a deadline, so a helper it leaves behind is ended with it.
    private func pullRequests(label: String, repo: String) -> [(number: Int, head: String)]? {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        if environment["AGENCIL_TEST_SEAMS"] == "1", let prefix = environment["AGENCIL_PATH_PREFIX"] { directories.insert(prefix, at: 0) }
        guard let gh = directories.map({ $0 + "/gh" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let argv = [gh, "pr", "list", "--state", "open", "--label", label, "--json", "number,headRefOid", "--limit", "100"]
        let directory = URL(fileURLWithPath: repo).resolvingSymlinksInPath()
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.output = try? await ProcessRunner().run(argv, in: directory, environment: ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"],
                                                        timeout: .seconds(20), gracePeriod: .seconds(2))
            done.signal()
        }
        done.wait()
        guard let output = box.output, output.status == 0,
              let list = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [[String: Any]] else { return nil }
        var found: [(Int, String)] = []
        for item in list {
            guard let number = item["number"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let n = item["number"] as? Int, n > 0,
                  let head = item["headRefOid"] as? String, head.range(of: Self.sha, options: .regularExpression) != nil else { return nil }
            found.append((n, head))
        }
        return found
    }

    private final class Box: @unchecked Sendable { var output: ProcessOutput? }

    // MARK: schedule

    private func scheduleCandidate(_ trigger: Trigger, now: Date) throws -> (Candidate?, String?) {
        guard let interval = trigger.scheduleSeconds else { return (nil, nil) }
        let epoch = Int(now.timeIntervalSince1970)
        guard let raw = try triggerRows.state(trigger.name, "schedule") else {
            try triggerRows.set(trigger.name, [("schedule", String(epoch))])
            return (nil, nil)
        }
        guard let last = Self.epoch(raw), Self.epoch(String(epoch)) != nil else { return (nil, "state_invalid") }
        guard epoch - last >= interval else { return (nil, nil) }
        return (Candidate(key: "schedule@\(epoch)", diff: "HEAD", commit: nil, consume: [("schedule", String(epoch))]), nil)
    }

    // MARK: the loop

    /// Evaluates every 30 seconds (the test seam overrides it); a failed pass is tried again at the next one.
    func startTriggerLoop() {
        let seconds = environment["AGENCIL_TEST_SEAMS"] == "1" ? environment["AGENCIL_TRIGGER_SECONDS"].flatMap(Double.init) ?? 30 : 30
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: seconds)
                _ = try? tick(now: Date())
            }
        }
    }
}

