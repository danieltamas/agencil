import Foundation

/// A path pattern, matched against a whole repo-relative path without regular expressions, so a hostile file name
/// cannot make a match run long: `*` within a segment, `?` one character, `**/` any number of segments (a trailing `**`
/// at least one).
struct Glob {
    private let segments: [Substring]

    init?(_ pattern: String) {
        guard !pattern.isEmpty else { return nil }
        segments = pattern.split(separator: "/", omittingEmptySubsequences: false)
    }

    func matches(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // reach[i][j]: segments[i...] match parts[j...]
        var reach = Array(repeating: Array(repeating: false, count: parts.count + 1), count: segments.count + 1)
        reach[segments.count][parts.count] = true
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            for j in stride(from: parts.count, through: 0, by: -1) {
                if segments[i] == "**" {
                    let last = i == segments.count - 1
                    // `**` takes zero segments unless it is the last one, then one or more.
                    let zero = !last && reach[i + 1][j]
                    let more = j < parts.count && (reach[i][j + 1] || (last && reach[i + 1][j + 1]))
                    reach[i][j] = zero || more
                } else if j < parts.count {
                    reach[i][j] = Self.segment(segments[i], parts[j]) && reach[i + 1][j + 1]
                }
            }
        }
        return reach[0][0]
    }

    /// `*` and `?` inside one segment, by the linear greedy walk with a single backtrack point.
    private static func segment(_ pattern: Substring, _ name: Substring) -> Bool {
        let p = Array(pattern.unicodeScalars), n = Array(name.unicodeScalars)
        var i = 0, j = 0, star = -1, mark = 0
        while j < n.count {
            if i < p.count, p[i] == "?" || (p[i] != "*" && p[i] == n[j]) { i += 1; j += 1 }
            else if i < p.count, p[i] == "*" { star = i; mark = j; i += 1 }
            else if star >= 0 { i = star + 1; mark += 1; j = mark }
            else { return false }
        }
        while i < p.count, p[i] == "*" { i += 1 }
        return i == p.count
    }
}
