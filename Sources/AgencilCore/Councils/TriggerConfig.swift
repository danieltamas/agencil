import Foundation

/// A rule that wakes a council by itself (docs/U7-SPEC.md "Triggers (U7b)").
public struct Trigger: Equatable, Sendable {
    public let name: String
    public let council: String
    public let repo: String
    public let paths: [String]?
    public let prLabel: String?
    /// Seconds between schedule fires.
    public let scheduleSeconds: Int?
    public let debounceSeconds: Int
    /// Minutes since midnight, start inclusive and end exclusive; the window may wrap midnight.
    public let quiet: (start: Int, end: Int)?
    public let changeKind: String
    public let question: String
    public let authorVendor: String?

    public var kinds: [String] {
        [paths == nil ? nil : "paths", prLabel == nil ? nil : "pr_label", scheduleSeconds == nil ? nil : "schedule"].compactMap { $0 }
    }

    public static func == (lhs: Trigger, rhs: Trigger) -> Bool { lhs.name == rhs.name && lhs.council == rhs.council && lhs.repo == rhs.repo }

    func isQuiet(minute: Int) -> Bool {
        guard let quiet else { return false }
        return quiet.start < quiet.end ? (quiet.start..<quiet.end).contains(minute) : (minute >= quiet.start || minute < quiet.end)
    }
}

extension SeatConfig {
    static func parseTriggers(_ text: String?, councils: [Council]) throws -> [Trigger] {
        var seen = Set<String>()
        let known = Set(councils.map(\.name))
        return try array(text, "triggers").map { item in
            let label = (item["name"] as? String) ?? "(unnamed)"
            func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "triggers", problem: "trigger \(label) \(problem)") }
            guard let name = item["name"] as? String, name.range(of: #"\A[a-z0-9][a-z0-9-]{0,39}\z"#, options: .regularExpression) != nil else {
                throw fail("needs a name of 1 to 40 characters of a-z, 0-9 and dashes")
            }
            guard seen.insert(name).inserted else { throw fail("is listed twice") }
            guard let council = item["council"] as? String, known.contains(council) else { throw fail("names a council that is not configured") }
            guard let repo = item["repo"] as? String, repo.hasPrefix("/") else { throw fail("needs an absolute repo path") }
            func text(_ key: String) throws -> String? {
                guard let value = item[key] else { return nil }
                guard let string = value as? String, !string.isEmpty else { throw fail("has a bad \(key)") }
                return string
            }
            func whole(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
                guard let value = item[key] else { return nil }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let int = value as? Int, range.contains(int) else { throw fail("has a bad \(key)") }
                return int
            }
            var paths: [String]?
            if let value = item["paths"] {
                guard let list = value as? [String], !list.isEmpty, !list.contains(where: \.isEmpty) else { throw fail("has a bad paths list") }
                paths = list
            }
            let prLabel = try text("pr_label")
            var seconds: Int?
            if let schedule = try text("schedule") {
                guard schedule.range(of: #"\Aevery ([1-9][0-9]{0,3}|10000)(m|h)\z"#, options: .regularExpression) != nil else {
                    throw fail("has a bad schedule (every <n>m or every <n>h)")
                }
                guard let count = Int(schedule.dropFirst(6).dropLast()) else { throw fail("has a bad schedule (every <n>m or every <n>h)") }
                seconds = count * (schedule.hasSuffix("h") ? 3600 : 60)
            }
            guard paths != nil || prLabel != nil || seconds != nil else { throw fail("needs paths, pr_label or schedule") }
            var quiet: (Int, Int)?
            if let hours = try text("quiet_hours") {
                let pattern = #"\A([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])\z"#
                guard hours.range(of: pattern, options: .regularExpression) != nil else { throw fail("has bad quiet_hours (HH:MM-HH:MM)") }
                let parts = hours.split(whereSeparator: { ":-".contains($0) }).compactMap { Int($0) }
                guard parts.count == 4, parts[0] * 60 + parts[1] != parts[2] * 60 + parts[3] else { throw fail("has bad quiet_hours (HH:MM-HH:MM)") }
                quiet = (parts[0] * 60 + parts[1], parts[2] * 60 + parts[3])
            }
            return Trigger(name: name, council: council, repo: repo, paths: paths, prLabel: prLabel, scheduleSeconds: seconds,
                           debounceSeconds: try whole("debounce_seconds", 0...86400) ?? 300, quiet: quiet,
                           changeKind: try text("change_kind") ?? "code",
                           question: try text("question") ?? "Review the change since the last sitting.",
                           authorVendor: try text("author_vendor"))
        }
    }
}
