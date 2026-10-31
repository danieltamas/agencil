import Foundation

/// The scalar and list settings of the Data, Leaderboard and Budgets panes (docs/U19-SPEC.md).
extension ConfigEditor {
    static let paneKeys: Set<String> = ["retention_raw_days", "leaderboard_repo", "leaderboard_min_n", "leaderboard_enabled"]

    static func paneProblem(_ key: String, _ value: String) -> String? {
        switch key {
        case "retention_raw_days":
            guard let days = Int(value), String(days) == value, (1...3650).contains(days) else { return "a whole number of days from 1 to 3650" }
        case "leaderboard_min_n":
            guard let count = Int(value), String(count) == value, (10...1000).contains(count) else { return "a whole number from 10 to 1000" }
        case "leaderboard_repo":
            do { _ = try LeaderboardSettings(values: ["leaderboard_repo": value]) } catch { return "owner/name" }
        case "leaderboard_enabled":
            if value != "0" { return "only the first manual publish turns this on" }
        default: break
        }
        return nil
    }

    // MARK: memory export targets

    @discardableResult
    public func addMemoryTarget(repo: String, folder: String) throws -> ConfigSnapshot {
        try changeTargets { targets in
            guard !targets.contains(where: { $0.repo == repo }) else { throw SheetProblems(fields: ["repo": "this repo is already listed"]) }
            return targets + [MemoryTarget(repo: repo, folder: folder, enabled: false)]
        }
    }

    @discardableResult
    public func setMemoryTarget(repo: String, enabled: Bool) throws -> ConfigSnapshot {
        try changeTargets { targets in
            guard targets.contains(where: { $0.repo == repo }) else { throw SheetProblems(fields: ["repo": "unknown repo"]) }
            return targets.map { $0.repo == repo ? MemoryTarget(repo: repo, folder: $0.folder, enabled: enabled) : $0 }
        }
    }

    @discardableResult
    public func removeMemoryTarget(repo: String) throws -> ConfigSnapshot {
        try changeTargets { targets in
            guard targets.contains(where: { $0.repo == repo }) else { throw SheetProblems(fields: ["repo": "unknown repo"]) }
            return targets.filter { $0.repo != repo }
        }
    }

    private func changeTargets(_ transform: ([MemoryTarget]) throws -> [MemoryTarget]) throws -> ConfigSnapshot {
        let snapshot = try read()
        let current: [[String: Any]]
        do { current = try SeatConfig.array(snapshot.values["memory_export"], "memory_export") } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
        let targets = try current.map { item -> MemoryTarget in
            guard let repo = item["repo"] as? String, let folder = item["folder"] as? String, let enabled = SeatConfig.flag(item["enabled"]) else {
                throw SheetProblems.form("memory_export entries need repo, folder and enabled")
            }
            return MemoryTarget(repo: repo, folder: folder, enabled: enabled)
        }
        let next = try transform(targets)
        do { try MemoryExport.validate(next) } catch let error as DataError { throw SheetProblems(fields: ["folder": error.message]) }
        let list = next.map { ["repo": $0.repo, "folder": $0.folder, "enabled": $0.enabled] as [String: Any] }
        do { _ = try SeatConfig(values: snapshot.values) } catch let problem as ConfigProblem { throw SheetProblems.form(problem.message) }
        return try write(snapshot, key: "memory_export", text: Self.json(list))
    }

    // MARK: budgets

    @discardableResult
    public func setBudget(name: String, scope: String, key: String, window: String, dollars: Double, hard: Bool) throws -> ConfigSnapshot {
        guard dollars >= 0, dollars.isFinite else { throw SheetProblems(fields: ["dollars": "zero or more"]) }
        return try changeBudgets { list in
            guard !list.contains(where: { $0["name"] as? String == name }) else { throw SheetProblems(fields: ["name": "this name is taken"]) }
            return list + [["name": name, "scope": scope, "key": key, "window": window, "dollars": dollars, "hard": hard]]
        }
    }

    @discardableResult
    public func removeBudget(name: String) throws -> ConfigSnapshot {
        try changeBudgets { list in
            guard list.contains(where: { $0["name"] as? String == name }) else { throw SheetProblems(fields: ["name": "unknown budget"]) }
            return list.filter { $0["name"] as? String != name }
        }
    }

    private func changeBudgets(_ transform: ([[String: Any]]) throws -> [[String: Any]]) throws -> ConfigSnapshot {
        let snapshot = try read()
        let current: [[String: Any]]
        do { current = try SeatConfig.array(snapshot.values["budgets"], "budgets") } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
        let next = try transform(current)
        let text = Self.json(next)
        var values = snapshot.values
        values["budgets"] = text
        do { _ = try SeatConfig(values: values) } catch let problem as ConfigProblem { throw SheetProblems.form(problem.message) }
        return try write(snapshot, key: "budgets", text: text)
    }
}
