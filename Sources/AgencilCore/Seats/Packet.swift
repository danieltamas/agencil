import Foundation

/// What one seat run is shown and where it works (docs/U6-SPEC.md "Ask with a repo", "Briefs").
struct Packet {
    let prompt: String
    /// The exported repo, which is also the seat's working directory; nil when the ask named no repo.
    let copy: URL?
}

extension Broker {
    func packet(seat: Seat, runDirectory: URL, repo: String?, question: String, files: [(path: String, text: String)],
                transcript: [(asked: String, answered: String)], snapshot: Snapshot? = nil, verbatim: Bool = false) throws -> Packet {
        var copy: URL?
        if let repo {
            let target = runDirectory.appendingPathComponent("copy")
            try RepoCopy.export(repo: repo, commit: snapshot?.commit ?? "HEAD", patch: snapshot?.patch, to: target)
            copy = target
        }
        var shown = files
        var withheld = 0
        if seat.hosted {
            let rules = try copy.map(Redaction.init(copy:)) ?? Redaction()
            if let copy { try rules.sweep(copy: copy) }
            shown = files.filter { !rules.withholds(attachment: $0.path, text: $0.text, base: repo) }
            withheld = files.count - shown.count
        }
        let briefsRoot = copy ?? (Adapter.restrictsExternalDirectories(seat.harness) ? runDirectory : nil)
        guard let briefsRoot, !shown.isEmpty else {
            return Packet(prompt: Adapter.prompt(question: question, files: shown, transcript: transcript, withheld: withheld, verbatim: verbatim), copy: copy)
        }
        let names = try RepoCopy.writeBriefs(shown, into: briefsRoot)
        return Packet(prompt: Adapter.prompt(question: question, files: [], transcript: transcript, attached: names, withheld: withheld, verbatim: verbatim),
                      copy: copy)
    }

    func removeStrandedCopies(except asking: Set<String>) {
        let runs = directory.appendingPathComponent("runs")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? [] where name.hasPrefix("th_") && !asking.contains(name) {
            try? FileManager.default.removeItem(at: runs.appendingPathComponent(name + "/copy"))
        }
    }

    /// Removes the exported repo of an exchange that has ended, whatever its outcome.
    func removeCopy(thread: String, seq: Int) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("runs/\(thread)-\(seq)/copy"))
    }
}

extension Broker {
    /// The `repo` of an ask: an absolute path that is the top of a git work tree, else the ask fails.
    func repository(_ value: Any?) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let path = value as? String, RepoCopy.isRepository(path) else {
            throw Refusal(exit: 4, message: "failed: repo \(value as? String ?? "") is not a git repository")
        }
        return path
    }

    /// The invocation started under the sandbox, with a private temporary directory inside the run directory.
    func confined(_ invocation: Invocation, copy: URL, runDirectory: URL, harness: String) throws -> Invocation {
        let launcher = try Confinement.executable(environment: environment)
        let temporary = runDirectory.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let argv = try Confinement.wrap(invocation.argv, launcher: launcher, copy: copy, runDirectory: runDirectory, harness: harness,
                                        home: Confinement.home(environment: environment))
        return Invocation(argv: argv, environment: invocation.environment.merging(["TMPDIR": temporary.path]) { _, mine in mine },
                          workingDirectory: copy.path, stdoutIsAnswer: invocation.stdoutIsAnswer, usage: invocation.usage)
    }
}
