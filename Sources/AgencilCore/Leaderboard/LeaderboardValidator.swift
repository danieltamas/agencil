import Foundation

/// The same allowlist `scripts/leaderboard/validate.py` applies in CI: exact keys, plain numbers, restricted strings.
public enum LeaderboardValidator {
    private static let topKeys: Set<String> = ["schema", "generated_at", "window", "outcomes_total", "min_n", "cells"]
    private static let required: Set<String> = ["model", "harness", "change_kind", "n", "confirmed", "refuted", "unresolved",
                                                "confirmed_share", "confirmed_share_ci", "golden_n"]
    private static let optional: Set<String> = ["coverage", "coverage_ci", "golden_recall", "median_seconds", "cost_per_confirmed_usd"]

    public static func validate(_ json: Data, aliasesOnMain: Set<String>) throws {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw fail("not a JSON object") }
        guard Set(root.keys) == topKeys else { throw fail("top-level keys are not exactly the schema") }
        guard int(root["schema"]) == LeaderboardExport.schema else { throw fail("unknown schema") }
        guard let outcomes = int(root["outcomes_total"]), outcomes >= 0 else { throw fail("outcomes_total") }
        guard let minN = int(root["min_n"]), minN >= LeaderboardExport.floorN else { throw fail("min_n is below the floor") }
        try time(root["generated_at"], "generated_at")
        guard let window = root["window"] as? [String: Any], Set(window.keys) == ["from", "to"] else { throw fail("window keys") }
        try time(window["from"], "window.from")
        try time(window["to"], "window.to")
        guard let cells = root["cells"] as? [Any] else { throw fail("cells is not a list") }
        for item in cells {
            guard let cell = item as? [String: Any] else { throw fail("a cell is not an object") }
            try validate(cell: cell, minN: minN, aliasesOnMain: aliasesOnMain)
        }
    }

    private static func validate(cell: [String: Any], minN: Int, aliasesOnMain: Set<String>) throws {
        let keys = Set(cell.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw fail("cell keys") }
        guard let model = cell["model"] as? String, PublicModels.matchesPattern(model),
              PublicModels.isPublic(model) || aliasesOnMain.contains(model) else { throw fail("model is not public") }
        guard let harness = cell["harness"] as? String, SeatConfig.harnesses.contains(harness) else { throw fail("harness") }
        guard let kind = cell["change_kind"] as? String, LeaderboardExport.changeKinds.contains(kind) else { throw fail("change_kind") }
        var counts: [String: Int] = [:]
        for name in ["n", "confirmed", "refuted", "unresolved", "golden_n"] {
            guard let value = int(cell[name]), value >= 0 else { throw fail("\(name) is not a non-negative integer") }
            counts[name] = value
        }
        guard counts["n"] == counts["confirmed", default: 0] + counts["refuted", default: 0] else { throw fail("n != confirmed + refuted") }
        guard counts["n", default: 0] >= minN else { throw fail("n is below min_n") }
        try unit(cell["confirmed_share"], "confirmed_share")
        try interval(cell["confirmed_share_ci"], "confirmed_share_ci")
        if cell["coverage"] != nil { try unit(cell["coverage"], "coverage") }
        if cell["coverage_ci"] != nil { try interval(cell["coverage_ci"], "coverage_ci") }
        if cell["golden_recall"] != nil { try unit(cell["golden_recall"], "golden_recall") }
        guard (counts["golden_n", default: 0] > 0) == (cell["golden_recall"] != nil) else { throw fail("golden_recall needs golden_n > 0 and the reverse") }
        for name in ["median_seconds", "cost_per_confirmed_usd"] where cell[name] != nil {
            guard let value = number(cell[name]), value >= 0 else { throw fail("\(name)") }
        }
    }

    private static func fail(_ message: String) -> LeaderboardError { LeaderboardError(message: "invalid data: \(message)") }

    /// A JSON number that is not a boolean.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        guard let double = number(value), double == double.rounded(), abs(double) < 1e12 else { return nil }
        return Int(double)
    }

    private static func unit(_ value: Any?, _ name: String) throws {
        guard let double = number(value), (0...1).contains(double) else { throw fail("\(name) is outside [0,1]") }
    }

    private static func interval(_ value: Any?, _ name: String) throws {
        guard let pair = value as? [Any], pair.count == 2, let low = number(pair[0]), let high = number(pair[1]),
              (0...1).contains(low), (0...1).contains(high), low <= high else { throw fail("\(name) is not an ordered pair in [0,1]") }
    }

    private static func time(_ value: Any?, _ name: String) throws {
        guard let text = value as? String,
              text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#, options: .regularExpression) != nil,
              OutcomeBook.clock.date(from: text) != nil
        else { throw fail("\(name) is not a plain UTC time") }
    }
}
