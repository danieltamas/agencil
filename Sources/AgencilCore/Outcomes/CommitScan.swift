import Foundation

/// Reads the git history of the repos councils sat on and offers each commit message as outcome evidence (docs/U24-SPEC.md).
public struct CommitScan: Sendable {
    private static let limit = 200
    private static let firstWindow: TimeInterval = 30 * 86_400
    /// The repository's own configuration must not run programs on a scan's behalf (signature checking is one).
    private static let inert = ["-c", "log.showSignature=false", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    private let ledger: Ledger
    private let directory: URL
    private var stateURL: URL { directory.appendingPathComponent("evidence-scan.json") }

    public init(ledger: Ledger, directory: URL) {
        self.ledger = ledger
        self.directory = directory
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The number of commits offered to `recordCommit`. A repo that is missing or has no commits is skipped; a repo whose
    /// history could not be read keeps its cursor, and the first such failure is thrown after the other repos ran.
    @discardableResult
    public func run(now: Date) throws -> Int {
        let repos = try ledger.locked {
            try ledger.query("SELECT DISTINCT repo FROM sittings WHERE repo IS NOT NULL ORDER BY repo;", []) { Ledger.text($0, 0) ?? "" }
        }
        var state = readState()
        var offered = 0
        var failure: Failure?
        for repo in repos where repo.hasPrefix("/") && FileManager.default.fileExists(atPath: repo) {
            guard let head = git(repo, ["rev-parse", "--verify", "HEAD^{commit}"]), head.count == 40 else { continue }
            do {
                let batch = try batch(in: repo, since: state[repo], head: head, now: now)
                for commit in try messages(batch.shas, in: repo) {
                    try OutcomeBook(ledger: ledger).recordCommit(sha: commit.sha, body: commit.body,
                                                                 revertedBody: try reverted(commit.body, in: repo), at: now)
                    offered += 1
                }
                state[repo] = batch.cursor
            } catch let problem as Failure {
                failure = failure ?? problem
            }
        }
        try writeState(state)
        if let failure { throw failure }
        return offered
    }

    /// The commits to offer, oldest first, and the cursor that covers exactly them. The first scan takes the newest ones
    /// of the last 30 days; later scans take the oldest ones after the cursor, so a large backlog is worked off in order.
    private func batch(in repo: String, since last: String?, head: String, now: Date) throws -> (shas: [String], cursor: String) {
        let continues = last.map { git(repo, ["merge-base", "--is-ancestor", $0, "HEAD"], status: true) == "0" } ?? false
        var range = ["rev-list", "--reverse"]
        if let last, continues { range.append("\(last)..HEAD") } else {
            range += ["--since=\(Int(now.addingTimeInterval(-Self.firstWindow).timeIntervalSince1970))", "HEAD"]
        }
        guard let listing = git(repo, range) else { throw Failure(message: "cannot list the history of \(repo)") }
        let shas = listing.split(separator: "\n").map(String.init)
        guard shas.allSatisfy({ Self.isObjectID($0) }) else { throw Failure(message: "unexpected history listing for \(repo)") }
        if continues {
            let taken = Array(shas.prefix(Self.limit))
            return (taken, taken.count == shas.count ? head : taken.last ?? head)
        }
        return (Array(shas.suffix(Self.limit)), head)
    }

    /// Messages of exactly the requested commits, framed by NUL (which no message holds) and checked against the request.
    private func messages(_ shas: [String], in repo: String) throws -> [(sha: String, body: String)] {
        guard !shas.isEmpty else { return [] }
        guard let data = RepoCopy.data(["-C", repo] + Self.inert + ["log", "--no-walk=unsorted", "--no-show-signature", "-z", "--format=%H%n%B"] + shas) else {
            throw Failure(message: "cannot read the commits of \(repo)")
        }
        let records = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard records.count == shas.count else { throw Failure(message: "unexpected commit listing for \(repo)") }
        return try zip(shas, records).map { sha, record in
            let body = record.drop { $0 != "\n" }.dropFirst()
            guard record.hasPrefix(sha + "\n") || record == sha else { throw Failure(message: "unexpected commit record for \(repo)") }
            return (sha, String(body))
        }
    }

    /// The message of the commit a revert undoes: nil when that commit does not exist, a failure when git could not say.
    private func reverted(_ body: String, in repo: String) throws -> String? {
        guard let target = CommitEvidenceParser.revertedSHA(in: body) else { return nil }
        guard let status = git(repo, ["cat-file", "-e", "\(target)^{commit}"], status: true) else {
            throw Failure(message: "cannot look up \(target) in \(repo)")
        }
        guard status == "0" else { return nil }
        guard let message = git(repo, ["show", "-s", "--no-show-signature", "--format=%B", target]) else {
            throw Failure(message: "cannot read \(target) in \(repo)")
        }
        return message
    }

    private static func isObjectID(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Trimmed output, or (with `status`) the exit status as text; nil when git could not run or was ended by its deadline.
    private func git(_ repo: String, _ arguments: [String], status: Bool = false) -> String? {
        let full = ["-C", repo] + Self.inert + arguments
        if status { return RepoCopy.status(full).map(String.init) }
        return RepoCopy.output(full)
    }

    private func readState() -> [String: String] {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func writeState(_ state: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try McpInstaller.writeAtomically(try encoder.encode(state), to: stateURL)
    }
}
