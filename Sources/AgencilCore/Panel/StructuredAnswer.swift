import Foundation

/// A council seat's answer read as the structure it is: claims, assessments of other seats' claims, a vote and notes
/// (docs/AGENT-API.md "Seat answer contract"). Nil for anything that is not such a JSON object, so free prose stays prose.
public struct StructuredAnswer: Sendable, Equatable {
    public struct Claim: Sendable, Equatable, Identifiable {
        public let id: String
        public let severity: String
        public let kind: String
        public let place: String?
        public let body: ClaimBody
    }

    public struct Assessment: Sendable, Equatable, Identifiable {
        public let claim: String
        /// `support`, `dispute` or `abstain`.
        public let stance: String
        public let why: String?
        public var id: String { claim }
    }

    public let claims: [Claim]
    public let assessments: [Assessment]
    /// `approve`, `block` or `abstain`; nil in a challenge round, where the earlier vote stands.
    public let vote: String?
    public let notes: String?

    public init?(_ answer: String) {
        let body = ReadableAnswer.unfenced(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard body.first == "{", let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              root["claims"] != nil || root["assessments"] != nil || root["vote"] != nil || root["notes"] != nil else { return nil }
        claims = ((root["claims"] as? [Any]) ?? []).compactMap { item in
            guard let claim = item as? [String: Any] else { return nil }
            let place = (claim["file"] as? String).map { file in (claim["line"] as? NSNumber).map { "\(file):\($0.intValue)" } ?? file }
            return Claim(id: claim["id"] as? String ?? "", severity: (claim["severity"] as? String ?? "p3").uppercased(),
                         kind: claim["kind"] as? String ?? "note", place: place,
                         body: ClaimBody(text: claim["evidence"] as? String ?? "", fix: claim["fix"] as? String,
                                         confidence: (claim["confidence"] as? NSNumber)?.doubleValue))
        }
        assessments = ((root["assessments"] as? [Any]) ?? []).compactMap { item in
            guard let value = item as? [String: Any], let claim = value["claim"] as? String else { return nil }
            return Assessment(claim: claim, stance: value["stance"] as? String ?? "abstain", why: value["why"] as? String)
        }
        vote = root["vote"] as? String
        notes = (root["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A brief as the council received it: `key: value` lines, a value running on until the next key.
public enum BriefFacts {
    public static func parse(_ text: String) -> [(name: String, value: String)]? {
        var facts: [(name: String, value: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let colon = line.firstIndex(of: ":"), colon != line.startIndex, line.distance(from: line.startIndex, to: colon) <= 24,
               line[..<colon].allSatisfy({ $0.isLetter || $0 == "_" }) {
                let key = line[..<colon].replacingOccurrences(of: "_", with: " ")
                facts.append((key.prefix(1).uppercased() + key.dropFirst(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            } else if !facts.isEmpty {
                facts[facts.count - 1].value += "\n" + line
            } else {
                return nil
            }
        }
        return facts.isEmpty ? nil : facts.map { ($0.name, $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
