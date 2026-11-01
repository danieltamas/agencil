import Foundation

/// The background jobs of docs/U20-SPEC.md, each gated by its own last run in `maintenance.json`.
public final class Maintenance: @unchecked Sendable {
    private static let retry: Double = 3600
    private static let publishHour = 6
    private static let outcomesBeforeEarlyPublish = 10

    private let ledger: Ledger
    private let directory: URL
    private let github: (String) -> GitHubClient
    private var cache: [String: Entry] = [:]
    private var unwritable = false
    private var stateURL: URL { directory.appendingPathComponent("maintenance.json") }

    public convenience init(ledger: Ledger, directory: URL, github: GitHubClient) {
        self.init(ledger: ledger, directory: directory, githubFor: { _ in github })
    }

    /// `githubFor` receives the configured leaderboard repository, so the client can be pinned to it.
    public init(ledger: Ledger, directory: URL, githubFor: @escaping (String) -> GitHubClient) {
        self.ledger = ledger
        self.directory = directory
        self.github = githubFor
    }

    /// Runs what is due and returns the names of the jobs that succeeded, in a fixed order.
    @discardableResult
    public func run(now: Date, calendar: Calendar = .current) -> [String] {
        guard let values = try? ConfigStore(directory: directory).read().values, (try? SeatConfig(values: values)) != nil,
              let settings = try? LeaderboardSettings(values: values),
              (try? Retention(ledger: ledger, directory: directory).days()) != nil,
              (try? MemoryExport(ledger: ledger, directory: directory).targets()) != nil else { return [] }
        var state = readState()
        var ran: [String] = []
        let seconds = now.timeIntervalSince1970
        let jobs: [(name: String, due: (Entry) -> Bool, work: () throws -> Void)] = [
            ("prune", { Self.elapsed($0, seconds, 86_400) }, { _ = try Retention(ledger: self.ledger, directory: self.directory).prune(now: now) }),
            ("memory", { Self.elapsed($0, seconds, 600) }, { _ = try MemoryExport(ledger: self.ledger, directory: self.directory).run(now: now) }),
            ("evidence", { Self.elapsed($0, seconds, 600) }, { _ = try CommitScan(ledger: self.ledger, directory: self.directory).run(now: now) }),
            ("learn", { Self.elapsed($0, seconds, 7 * 86_400) }, {
                let config = try SeatConfig(values: values)
                try LearnLoop(ledger: self.ledger, directory: self.directory).propose(now: now, candidates: config.seats, ideas: [])
            }),
        ]
        for job in jobs where Self.mayAttempt(state[job.name], seconds) && job.due(state[job.name] ?? Entry()) {
            if attempt(job.name, &state, seconds, job.work) { ran.append(job.name) }
        }
        if values["leaderboard_enabled"] == "1", Self.mayAttempt(state["leaderboard"], seconds),
           let total = try? outcomeCount(), leaderboardDue(state["leaderboard"] ?? Entry(), now, calendar, total) {
            let publisher = LeaderboardPublisher(ledger: ledger, directory: directory, github: github(settings.repo))
            if attempt("leaderboard", &state, seconds, { _ = try publisher.publishScheduled(now: now, golden: [:]) }) {
                state["leaderboard", default: Entry()].outcomesAtPublish = total
                ran.append("leaderboard")
            }
        }
        writeState(state)
        return ran
    }

    /// For the `data` op: each job's last run and last error.
    public func jobs() -> [String: [String: Any]] {
        readState().mapValues { entry in
            var row: [String: Any] = [:]
            if let last = entry.lastRun { row["last_run"] = last }
            if let error = entry.lastError { row["last_error"] = error }
            return row
        }
    }

    // MARK: due rules

    private func leaderboardDue(_ entry: Entry, _ now: Date, _ calendar: Calendar, _ total: Int) -> Bool {
        guard let today = calendar.date(bySettingHour: Self.publishHour, minute: 0, second: 0, of: now) else { return false }
        let last = entry.lastRun.map { Date(timeIntervalSince1970: $0) }
        if now >= today, last.map({ $0 < today }) ?? true { return true }
        guard let last else { return false }
        return total - (entry.outcomesAtPublish ?? total) >= Self.outcomesBeforeEarlyPublish && now.timeIntervalSince(last) >= Self.retry
    }

    private static func elapsed(_ entry: Entry, _ now: Double, _ interval: Double) -> Bool {
        entry.lastRun.map { now - $0 >= interval } ?? true
    }

    /// A failed job waits an hour from its last attempt.
    private static func mayAttempt(_ entry: Entry?, _ now: Double) -> Bool {
        guard let entry, entry.lastError != nil, let attempt = entry.lastAttempt else { return true }
        return now - attempt >= retry
    }

    private func attempt(_ name: String, _ state: inout [String: Entry], _ now: Double, _ work: () throws -> Void) -> Bool {
        var entry = state[name] ?? Entry()
        entry.lastAttempt = now
        do {
            try work()
            entry.lastRun = now
            entry.lastError = nil
            state[name] = entry
            return true
        } catch {
            entry.lastError = error.localizedDescription
            state[name] = entry
            return false
        }
    }

    private func outcomeCount() throws -> Int {
        try ledger.locked { try ledger.query("SELECT count(*) FROM outcomes;", []) { Int(Ledger.text($0, 0) ?? "") ?? 0 }.first ?? 0 }
    }

    // MARK: state file

    private struct Entry: Codable {
        var lastRun: Double?
        var lastError: String?
        var lastAttempt: Double?
        var outcomesAtPublish: Int?

        enum CodingKeys: String, CodingKey {
            case lastRun = "last_run", lastError = "last_error", lastAttempt = "last_attempt", outcomesAtPublish = "outcomes_at_publish"
        }
    }

    private func readState() -> [String: Entry] {
        if unwritable { return cache }
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return state
    }

    private func writeState(_ state: [String: Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        cache = state
        do { try McpInstaller.writeAtomically(data, to: stateURL); unwritable = false } catch { unwritable = true }
    }
}
