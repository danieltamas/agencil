import Foundation

/// One piece of outcome evidence for a claim. Evidence is never a label.
public struct EvidenceRecord: Equatable, Sendable {
    public let claim: String
    public let source: String
    public let detail: String
}

/// Reads claim ids and reverts out of commit and PR text.
public enum CommitEvidenceParser {
    private static let claimID = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9-])AG-[0-9]+-[0-9]+(?![A-Za-z0-9-])")
    private static let revert = try! NSRegularExpression(pattern: "(?m)^This reverts commit ([0-9a-fA-F]{40})\\.?[ \\t]*$")

    /// Every whole `AG-<sitting>-<k>` id, in order of appearance, once.
    public static func claimIDs(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return claimID.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    public static func revertedSHA(in body: String) -> String? {
        let range = NSRange(body.startIndex..., in: body)
        return revert.firstMatch(in: body, range: range).flatMap { Range($0.range(at: 1), in: body) }.map { String(body[$0]) }
    }
}
