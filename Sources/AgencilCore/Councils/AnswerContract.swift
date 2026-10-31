import Foundation

struct SeatClaim: Equatable {
    let localID: String
    let kind: String
    let severity: String
    let confidence: Double
    let file: String?
    let line: Int?
    let evidence: String?
    let fix: String?
}

struct SeatAssessment: Equatable {
    let claim: String
    let stance: String
    let why: String?
}

struct SeatAnswer: Equatable {
    var claims: [SeatClaim]
    var assessments: [SeatAssessment]
    /// Nil only in a challenge round, where the seat's earlier vote stands.
    var vote: String?
    var notes: String?
}

/// The fixed JSON shape seats of a council answer in (docs/AGENT-API.md "Seat answer contract").
enum AnswerContract {
    struct Problem: Error, Equatable { let message: String }

    static let evidenceLimit = 4096
    private static let kinds: Set<String> = ["defect", "risk", "question", "note"]
    private static let severities: Set<String> = ["p0", "p1", "p2", "p3"]
    private static let votes: Set<String> = ["approve", "block", "abstain"]
    private static let stances: Set<String> = ["support", "dispute", "abstain"]

    /// The JSON text of an answer: the whole trimmed output, else the first fenced block in it.
    private static func object(in text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let fence = try? NSRegularExpression(pattern: "```[a-zA-Z]*[ \\t]*\\n(.*?)\\n[ \\t]*```", options: [.dotMatchesLineSeparators]),
           let match = fence.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed) {
            candidates.append(String(trimmed[range]))
        }
        for candidate in candidates {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) {
                guard let object = parsed as? [String: Any] else { throw Problem(message: "the answer must be a JSON object") }
                return object
            }
        }
        throw Problem(message: "the answer is not valid JSON")
    }

    /// Cuts at a UTF-8 boundary.
    static func bounded(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var cut = limit
        while cut > 0, String(bytes: Array(text.utf8.prefix(cut)), encoding: .utf8) == nil { cut -= 1 }
        return String(decoding: Array(text.utf8.prefix(cut)), as: UTF8.self)
    }

    static func parse(_ text: String, requireVote: Bool = true) -> Result<SeatAnswer, Problem> {
        do {
            let root = try object(in: text)
            var answer = SeatAnswer(claims: [], assessments: [], vote: nil, notes: root["notes"] as? String)
            if let vote = root["vote"] {
                guard let name = vote as? String, votes.contains(name) else { throw Problem(message: "vote must be approve, block or abstain") }
                answer.vote = name
            } else if requireVote {
                throw Problem(message: "vote is required")
            }
            if let claims = root["claims"] {
                guard let list = claims as? [Any] else { throw Problem(message: "claims must be a list") }
                for (index, item) in list.enumerated() { answer.claims.append(try claim(item, index: index)) }
            } else if requireVote {
                throw Problem(message: "claims is required")
            }
            if let assessments = root["assessments"] {
                guard let list = assessments as? [Any] else { throw Problem(message: "assessments must be a list") }
                for (index, item) in list.enumerated() { answer.assessments.append(try assessment(item, index: index)) }
            }
            return .success(answer)
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(message: "the answer does not validate"))
        }
    }

    private static func claim(_ item: Any, index: Int) throws -> SeatClaim {
        let label = "claims[\(index)]"
        guard let claim = item as? [String: Any] else { throw Problem(message: "\(label) must be an object") }
        guard let id = claim["id"] as? String, !id.isEmpty else { throw Problem(message: "\(label).id must be a non-empty string") }
        guard let kind = claim["kind"] as? String, kinds.contains(kind) else { throw Problem(message: "\(label).kind must be defect, risk, question or note") }
        guard let severity = claim["severity"] as? String, severities.contains(severity) else { throw Problem(message: "\(label).severity must be p0, p1, p2 or p3") }
        guard let confidence = SeatConfig.number(claim["confidence"]), (0.0...1.0).contains(confidence) else {
            throw Problem(message: "\(label).confidence must be a number from 0 to 1")
        }
        var line: Int?
        if let value = claim["line"] {
            guard let number = SeatConfig.whole(value), number >= 1 else { throw Problem(message: "\(label).line must be a whole number from 1") }
            line = number
        }
        for key in ["file", "evidence", "fix"] where claim[key] != nil && claim[key] as? String == nil {
            throw Problem(message: "\(label).\(key) must be a string")
        }
        return SeatClaim(localID: id, kind: kind, severity: severity, confidence: confidence, file: claim["file"] as? String, line: line,
                         evidence: (claim["evidence"] as? String).map { bounded($0, evidenceLimit) }, fix: claim["fix"] as? String)
    }

    private static func assessment(_ item: Any, index: Int) throws -> SeatAssessment {
        let label = "assessments[\(index)]"
        guard let value = item as? [String: Any] else { throw Problem(message: "\(label) must be an object") }
        guard let claim = value["claim"] as? String, !claim.isEmpty else { throw Problem(message: "\(label).claim must be a claim id") }
        guard let stance = value["stance"] as? String, stances.contains(stance) else {
            throw Problem(message: "\(label).stance must be support, dispute or abstain")
        }
        return SeatAssessment(claim: claim, stance: stance, why: value["why"] as? String)
    }

    /// The synthesizer's `{"summary": "..."}`.
    static func parseSummary(_ text: String) -> Result<String, Problem> {
        do {
            let root = try object(in: text)
            guard let summary = root["summary"] as? String, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Problem(message: "summary must be a non-empty string")
            }
            return .success(summary)
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(message: "the answer does not validate"))
        }
    }
}
