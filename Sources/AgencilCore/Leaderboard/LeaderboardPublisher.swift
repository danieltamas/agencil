import Foundation

public struct GitHubResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol GitHubClient: Sendable {
    /// `path` is like `repos/o/r/contents/data.json?ref=leaderboard`.
    func get(_ path: String) throws -> GitHubResponse
    /// `body` is JSON.
    func put(_ path: String, body: Data) throws -> GitHubResponse
    /// `gh workflow run <workflow> --ref <ref>`.
    func dispatch(workflow: String, ref: String) throws
}

/// The `leaderboard_*` settings, each validated before anything is read from the ledger or sent anywhere.
struct LeaderboardSettings {
    static let defaultRepo = "danieltamas/agencil"
    static let defaultMinN = 20

    let repo: String
    let minN: Int
    let aliases: [String: String]
    let enabled: Bool

    init(values: [String: String]) throws {
        let repo = values["leaderboard_repo"] ?? Self.defaultRepo
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            part.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil && part != "." && part != ".."
        }) else { throw LeaderboardError(message: "leaderboard_repo must be owner/name") }
        self.repo = repo

        if let text = values["leaderboard_min_n"] {
            guard let value = Int(text) else { throw LeaderboardError(message: "leaderboard_min_n must be a whole number") }
            minN = value
        } else {
            minN = Self.defaultMinN
        }

        var aliases: [String: String] = [:]
        if let text = values["leaderboard_aliases"] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw LeaderboardError(message: "leaderboard_aliases must be a JSON object")
            }
            for (local, value) in object {
                guard !local.isEmpty, let alias = value as? String, PublicModels.matchesPattern(alias) else {
                    throw LeaderboardError(message: "leaderboard_aliases values must be model names")
                }
                aliases[local] = alias
            }
        }
        self.aliases = aliases
        enabled = values["leaderboard_enabled"] == "1"
    }
}

/// Builds the aggregate file and writes it to the `leaderboard` branch of the owner's repository. The app never
/// touches another branch or path: CI renders the card from what is published here.
public final class LeaderboardPublisher: @unchecked Sendable {
    private static let branch = "leaderboard"
    private let ledger: Ledger
    private let store: ConfigStore
    private let github: GitHubClient

    public init(ledger: Ledger, directory: URL, github: GitHubClient) {
        self.ledger = ledger
        self.store = ConfigStore(directory: directory)
        self.github = github
    }

    /// Exactly the bytes a publish would send, after validation.
    public func preview(now: Date, golden: [String: GoldenScore]) throws -> Data {
        try render(LeaderboardSettings(values: store.read().values), values: store.read().values, now: now, golden: golden)
    }

    public func press(now: Date, golden: [String: GoldenScore]) throws {
        let values = try store.read().values, settings = try LeaderboardSettings(values: values)
        let bytes = try render(settings, values: values, now: now, golden: golden)
        try publish(bytes, to: settings.repo)
        _ = try store.update { $0["leaderboard_enabled"] = "1" }
        try dispatch()
    }

    /// False, with no request, until the owner pressed once and while the setting is anything but `1`.
    public func publishScheduled(now: Date, golden: [String: GoldenScore]) throws -> Bool {
        let values = try store.read().values
        guard values["leaderboard_enabled"] == "1" else { return false }
        let settings = try LeaderboardSettings(values: values)
        let bytes = try render(settings, values: values, now: now, golden: golden)
        try publish(bytes, to: settings.repo)
        try dispatch()
        return true
    }

    private func settings() throws -> LeaderboardSettings { try LeaderboardSettings(values: store.read().values) }

    private func render(_ settings: LeaderboardSettings, values: [String: String], now: Date,
                        golden: [String: GoldenScore]) throws -> Data {
        let data = try LeaderboardExport.build(ledger: ledger, config: SeatConfig(values: values), aliases: settings.aliases,
                                               aliasesOnMain: PublicModels.approvedAliases, golden: golden,
                                               minN: settings.minN, now: now)
        let bytes = try LeaderboardExport.canonicalJSON(data)
        try LeaderboardValidator.validate(bytes, aliasesOnMain: PublicModels.approvedAliases)
        return bytes
    }

    private func dispatch() throws { try github.dispatch(workflow: "leaderboard.yml", ref: "main") }

    private func currentSHA(_ repo: String) throws -> String? {
        let response = try github.get("repos/\(repo)/contents/data.json?ref=\(Self.branch)")
        switch response.status {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let sha = object["sha"] as? String, !sha.isEmpty else {
                throw LeaderboardError(message: "GitHub answered without a file sha")
            }
            return sha
        case 404: return nil
        default: throw LeaderboardError(message: "reading data.json failed with status \(response.status)")
        }
    }

    /// One write; a stale sha (409 or 422) re-reads and retries once, so two racing publishers cannot both win silently.
    private func publish(_ bytes: Data, to repo: String) throws {
        for attempt in 0..<2 {
            var body: [String: Any] = ["branch": Self.branch, "message": "Update leaderboard data",
                                       "content": bytes.base64EncodedString()]
            if let sha = try currentSHA(repo) { body["sha"] = sha }
            let response = try github.put("repos/\(repo)/contents/data.json",
                                          body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            if (200...201).contains(response.status) { return }
            guard attempt == 0, response.status == 409 || response.status == 422 else {
                throw LeaderboardError(message: "writing data.json failed with status \(response.status)")
            }
        }
    }
}
