import Foundation

/// A named set of seats with the rules of a sitting (docs/U7-SPEC.md "Config").
public struct Council: Equatable, Sendable {
    public enum Rule: String, Sendable { case anyBlocker = "any_blocker", unanimous, majority }
    /// `review` gates a change with claims and votes; `consult` keeps the seats' distinct positions apart (docs/U33-SPEC.md).
    public enum Mode: String, Sendable { case review, consult }

    public let name: String
    public let mode: Mode
    public let seats: [String]
    public let spares: [String]
    public let synthesizers: [String]
    public let rule: Rule
    public let highRisk: Bool
    public let quorum: Int?
    public let rebuttal: Bool
    public let challenge: Bool
    public let localOnly: Bool
    public let silentAfter: Double
    public let deadlineSeconds: Int
}

extension SeatConfig {
    public func council(named name: String) -> Council? { councils.first { $0.name == name } }

    static func vendor(of harness: String) -> String {
        switch harness {
        case "claude": "anthropic"
        case "codex": "openai"
        case "gemini": "google"
        default: harness
        }
    }

    static func parseCouncils(_ text: String?, seats: [Seat], aliases: [String: String]) throws -> [Council] {
        let seatNames = Set(seats.map(\.name))
        var seen = Set<String>()
        return try array(text, "councils").map { item in
            func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "councils", problem: problem) }
            guard let name = item["name"] as? String, name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
                throw fail("a council name is 1 to 40 characters of a-z, 0-9 and dashes")
            }
            // The mode decides what kind of council this is, so a bad one is reported before any check of its members.
            var mode = Council.Mode.review
            if let value = item["mode"] {
                guard let text = value as? String, let parsed = Council.Mode(rawValue: text) else { throw fail("council \(name) mode is review or consult") }
                mode = parsed
            }
            guard seen.insert(name).inserted else { throw fail("council \(name) is listed twice") }
            guard !seatNames.contains(name), aliases[name] == nil else { throw fail("council \(name) has the name of a seat or alias") }
            func names(_ key: String) throws -> [String]? {
                guard let value = item[key] else { return nil }
                guard let list = value as? [String] else { throw fail("council \(name) has a bad \(key) list") }
                guard Set(list).count == list.count else { throw fail("council \(name) lists a seat twice in \(key)") }
                if let unknown = list.first(where: { !seatNames.contains($0) }) { throw fail("council \(name) names \(unknown), which is not a seat") }
                return list
            }
            guard let members = try names("seats"), !members.isEmpty else { throw fail("council \(name) needs seats") }
            let spares = try names("spare") ?? []
            if let both = spares.first(where: members.contains) { throw fail("council \(name) lists \(both) as a seat and a spare") }
            var synthesizers: [String] = []
            if let value = item["synthesizer"] {
                if let single = value as? String { synthesizers = [single] }
                else if let list = value as? [String] { synthesizers = list }
                else { throw fail("council \(name) has a bad synthesizer") }
                if let unknown = synthesizers.first(where: { !seatNames.contains($0) }) {
                    throw fail("council \(name) names the synthesizer \(unknown), which is not a seat")
                }
                if let inside = synthesizers.first(where: { members.contains($0) || spares.contains($0) }) {
                    throw fail("council \(name) uses \(inside) as a synthesizer and a seat")
                }
            }
            var rule = Council.Rule.majority
            if let value = item["rule"] {
                guard let text = value as? String, let parsed = Council.Rule(rawValue: text) else { throw fail("council \(name) has an unknown rule") }
                rule = parsed
            }
            if let value = item["high_risk"], flag(value) == nil { throw fail("council \(name) has a bad high_risk flag") }
            var quorum: Int?
            if let value = item["quorum"] {
                guard let count = whole(value), (1...members.count).contains(count) else { throw fail("council \(name) needs a quorum from 1 to its seat count") }
                quorum = count
            }
            if let value = item["rounds"], value as? [String: Any] == nil { throw fail("council \(name) has a bad rounds object") }
            let rounds = item["rounds"] as? [String: Any] ?? [:]
            for key in ["rebuttal", "challenge"] where rounds[key] != nil && flag(rounds[key]) == nil {
                throw fail("council \(name) has a bad rounds.\(key)")
            }
            if let value = item["residency"], !["any", "local"].contains(value as? String ?? "") { throw fail("council \(name) residency is any or local") }
            var silent = 0.5
            if let value = item["silent_after"] {
                guard let number = number(value), (0.05...0.95).contains(number) else { throw fail("council \(name) silent_after is 0.05 to 0.95") }
                silent = number
            }
            var deadline = 1800
            if let value = item["deadline_seconds"] {
                guard let count = whole(value), (10...7200).contains(count) else { throw fail("council \(name) deadline_seconds is 10 to 7200") }
                deadline = count
            }
            return Council(name: name, mode: mode, seats: members, spares: spares, synthesizers: synthesizers, rule: rule,
                           highRisk: flag(item["high_risk"]) ?? false, quorum: quorum, rebuttal: flag(rounds["rebuttal"]) ?? true,
                           challenge: flag(rounds["challenge"]) ?? false, localOnly: item["residency"] as? String == "local",
                           silentAfter: silent, deadlineSeconds: deadline)
        }
    }
}
