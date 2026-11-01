import AgencilCore
import Foundation
import Observation

/// What the broker-fed panes show: harnesses, models, budgets and the Data pane. Each refresh is one op; a down
/// broker leaves the old rows and sets `problem`.
@MainActor @Observable final class PaneStore {
    struct Harness: Identifiable { let id: String; let found: Bool; let version: String; let signedIn: String }
    struct Model: Identifiable { let id: String; let seats: [String] }
    struct BudgetRow: Identifiable { let id: String; let detail: String }
    struct Target: Identifiable { let id: String; let folder: String; let enabled: Bool }

    /// The last preflight of one seat, in the panel's words: what the Seats pane shows and Re-check replaces.
    struct SeatStanding: Equatable {
        let text: String; let ok: Bool; let detail: String; let age: String?
        /// `usage limit until Nov 3, checked 12s ago`.
        var line: String { text + (age.map { ", checked \($0)" } ?? "") }
    }

    private(set) var harnesses: [Harness] = []
    private(set) var standings: [String: SeatStanding] = [:]
    private(set) var models: [Model] = []
    private(set) var budgets: [BudgetRow] = []
    private(set) var retentionDays = ""
    private(set) var databaseBytes: Int64 = 0
    private(set) var rawBytes: Int64 = 0
    private(set) var targets: [Target] = []
    private(set) var previewText: String?
    private(set) var problem: String?
    private(set) var lastCleanup = "never"

    @ObservationIgnored private let client: PanelClient?

    private(set) var leaderboardRepo = ""
    private(set) var leaderboardMinN = ""
    private(set) var leaderboardEnabled = false
    private(set) var fieldProblem: String?

    @ObservationIgnored private let editor: ConfigEditor?
    @ObservationIgnored private let directory: URL?

    init(directory: URL? = nil, client: PanelClient? = nil) {
        self.directory = directory
        self.client = client
        editor = directory.map { ConfigEditor(directory: $0) }
        readSettings()
    }

    /// Made-up standings and harness versions for the preview and the screenshots.
    static func demo() -> PaneStore {
        let store = PaneStore()
        store.harnesses = DemoPanel.harnesses.map { Harness(id: $0.name, found: $0.up, version: $0.detail, signedIn: "yes") }
        store.standings = [
            "codex-gpt": SeatStanding(text: "ok", ok: true, detail: "", age: "40s ago"),
            "claude-opus": SeatStanding(text: "ok", ok: true, detail: "", age: "40s ago"),
            "box-qwen3": SeatStanding(text: "usage limit until Nov 3, 9:00", ok: false, detail: "try again at Nov 3, 9:00", age: "12s ago"),
        ]
        return store
    }

    /// The scalar fields come from the file, not the broker, so they show even while the broker is down.
    func readSettings() {
        guard let directory, let values = try? ConfigStore(directory: directory).read().values else { return }
        leaderboardRepo = values["leaderboard_repo"] ?? "danieltamas/agencil"
        leaderboardMinN = values["leaderboard_min_n"] ?? "20"
        leaderboardEnabled = values["leaderboard_enabled"] == "1"
        if retentionDays.isEmpty { retentionDays = values["retention_raw_days"] ?? "90" }
    }

    func refresh(probe: Bool = false) async {
        guard let client else { return }
        do {
            let harnessData = try await client.call("harnesses", probe ? ["probe": true] : [:])
            harnesses = (harnessData["harnesses"] as? [[String: Any]] ?? []).map {
                Harness(id: $0["kind"] as? String ?? "?", found: $0["found"] as? Bool == true,
                        version: $0["version"] as? String ?? "-", signedIn: $0["signed_in"] as? String ?? "unknown")
            }
            models = (try await client.call("models")["models"] as? [[String: Any]] ?? []).map {
                Model(id: $0["model"] as? String ?? "?", seats: $0["seats"] as? [String] ?? [])
            }
            budgets = (try await client.call("budgets")["budgets"] as? [[String: Any]] ?? []).map {
                BudgetRow(id: $0["name"] as? String ?? "?", detail: Self.budgetDetail($0))
            }
            let data = try await client.call("data")
            retentionDays = String(data["retention_days"] as? Int ?? 0)
            let run = ((data["jobs"] as? [String: Any])?["prune"] as? [String: Any])?["last_run"] as? Double
            lastCleanup = run.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "never"
            databaseBytes = (data["database_bytes"] as? NSNumber)?.int64Value ?? 0
            rawBytes = (data["raw_bytes"] as? NSNumber)?.int64Value ?? 0
            targets = (data["memory_targets"] as? [[String: Any]] ?? []).map {
                Target(id: $0["repo"] as? String ?? "?", folder: $0["folder"] as? String ?? "", enabled: $0["enabled"] as? Bool == true)
            }
            // Last, so a broker that predates the op leaves every other pane whole.
            standings = try await Self.readStandings(client, seats: nil, probe: false).reduce(into: standings) { $0[$1.key] = $1.value }
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    /// `claude 2.3.1 - subscription - alias`: the harness with its version when it is found, the plan, the alias note.
    func seatMeta(_ harness: String, plan: String, model: String) -> String {
        let installed = harnesses.first { $0.id == harness && $0.found && $0.version != "-" }
        return PanelFormat.seatMeta(harness: installed.map { "\(harness) \($0.version)" } ?? harness, plan: plan, model: model)
    }

    /// Probes one seat now (an owner call) and replaces its standing with the answer.
    func recheck(_ seat: String) async {
        guard let client else { return }
        do {
            standings = try await Self.readStandings(client, seats: [seat], probe: true).reduce(into: standings) { $0[$1.key] = $1.value }
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    private static func readStandings(_ client: PanelClient, seats: [String]?, probe: Bool) async throws -> [String: SeatStanding] {
        var request: [String: Any] = probe ? ["probe": true] : [:]
        if let seats { request["seats"] = seats }
        let rows = try await client.call("preflight", request)["seats"] as? [[String: Any]] ?? []
        return Dictionary(rows.compactMap { row -> (String, SeatStanding)? in
            guard let name = row["name"] as? String else { return nil }
            let reason = row["reason"] as? String ?? "not probed"
            let age = (row["probed_ago"] as? NSNumber).map { PanelStore.age($0.doubleValue) + " ago" }
            return (name, SeatStanding(text: standingText(reason: reason, until: row["until"] as? String), ok: reason == "ok",
                                       detail: row["detail"] as? String ?? "", age: age))
        }, uniquingKeysWith: { _, last in last })
    }

    /// The reason in plain words, with the reset time a usage limit came with.
    static func standingText(reason: String, until: String?) -> String {
        guard let known = PreflightReason(rawValue: reason) else { return "not checked" }
        if known == .usageLimit, let until { return "usage limit until \(until)" }
        return known.standing
    }

    func prune() async {
        guard let client else { return }
        do {
            let report = try await client.call("prune")
            problem = nil
            await refresh()
            previewText = "Deleted \(report["files_deleted"] as? Int ?? 0) files, freed \(Self.size(report["bytes_freed"]))."
        } catch { problem = error.localizedDescription }
    }

    func preview() async {
        guard let client else { return }
        do {
            let data = try await client.call("leaderboard", ["action": "preview"])
            previewText = "\(data["cells"] as? Int ?? 0) cells, \((data["bytes"] as? String ?? "").utf8.count) bytes"
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    func publish() async {
        guard let client else { return }
        do {
            _ = try await client.call("leaderboard", ["action": "publish"])
            previewText = "Published."
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    static func size(_ value: Any?) -> String {
        ByteCountFormatter.string(fromByteCount: (value as? NSNumber)?.int64Value ?? 0, countStyle: .file)
    }
}

// MARK: saving

extension PaneStore {
    func save(_ key: String, _ value: String) {
        guard let editor else { return }
        do { try editor.set(key, value); fieldProblem = nil }
        catch { fieldProblem = (error as? SheetProblems)?.fields.values.first ?? error.localizedDescription }
        readSettings()
        if key == "retention_raw_days", fieldProblem == nil { retentionDays = value }
    }

    func edit(_ change: (ConfigEditor) throws -> Void) async {
        guard let editor else { return }
        do { try change(editor); fieldProblem = nil }
        catch { fieldProblem = (error as? SheetProblems)?.fields.values.first ?? error.localizedDescription }
        await refresh()
    }
}

extension PaneStore {
}

// MARK: actions for the views (async work stays in the store)

extension PaneStore {
    typealias Job = () async -> Void

    func begin() { Task { await refresh() } }
    func recheckAction(seat: String) -> Job { { [self] in await recheck(seat) } }
    func recheckAction() -> Job { { [self] in await refresh(probe: true) } }
    func pruneAction() -> Job { { [self] in await prune() } }
    func previewAction() -> Job { { [self] in await preview() } }
    func publishAction() -> Job { { [self] in await publish(); readSettings() } }
    func removeBudgetAction(_ name: String) -> Job { { [self] in await edit { try $0.removeBudget(name: name) } } }
    func removeTargetAction(_ repo: String) -> Job { { [self] in await edit { try $0.removeMemoryTarget(repo: repo) } } }
    func addTargetAction(repo: String, folder: String) -> Job { { [self] in await edit { try $0.addMemoryTarget(repo: repo, folder: folder) } } }

    func setTarget(_ repo: String, enabled: Bool) { Task { await edit { try $0.setMemoryTarget(repo: repo, enabled: enabled) } } }

    func addBudgetAction(vendor: String, dollars: String, hard: Bool) -> Job {
        { [self] in
            guard let amount = Double(dollars) else { fieldProblem = "Dollars must be a number."; return }
            await edit { try $0.setBudget(name: "\(vendor)-week", scope: "vendor", key: vendor, window: "week", dollars: amount, hard: hard) }
        }
    }
}

extension PaneStore {
    static func budgetDetail(_ row: [String: Any]) -> String {
        func dollars(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
        let limit = (row["dollars_limit"] as? Double).map(dollars) ?? "no dollar limit"
        return "\(row["scope"] as? String ?? "") \(row["key"] as? String ?? ""), spent \(dollars(row["spent_dollars"] as? Double ?? 0)) of \(limit)"
    }
}
