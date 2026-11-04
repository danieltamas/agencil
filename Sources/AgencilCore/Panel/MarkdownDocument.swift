import Foundation

/// The block structure of a Markdown text, for a synthesis the panel draws as formatted text. Only what a council's
/// summary uses is understood: headings, bullet and numbered lists, fenced code and paragraphs. Inline markup (`**bold**`,
/// `code`) stays in the text for the view to draw; a tag is plain text, never markup.
public enum MarkdownDocument {
    public enum Block: Equatable, Sendable {
        case heading(Int, String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case code(String)
    }

    /// Linear in the input: every line is looked at once.
    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = [], numbered: [String] = []
        var code: [String]?

        func flush() {
            // A seat's or an agent's line break is meant, not a soft wrap, so it stays.
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") { blocks.append(.code(code?.joined(separator: "\n") ?? "")); code = nil } else { code?.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if let heading = Self.heading(trimmed) { flush(); blocks.append(heading); continue }
            if let item = Self.bullet(trimmed) {
                if !bullets.isEmpty || (paragraph.isEmpty && numbered.isEmpty) { bullets.append(item); continue }
                flush(); bullets.append(item); continue
            }
            if let item = Self.numberedItem(trimmed) {
                if !numbered.isEmpty || (paragraph.isEmpty && bullets.isEmpty) { numbered.append(item); continue }
                flush(); numbered.append(item); continue
            }
            // A line under a list item continues that item.
            if !bullets.isEmpty { bullets[bullets.count - 1] += " " + trimmed; continue }
            if !numbered.isEmpty { numbered[numbered.count - 1] += " " + trimmed; continue }
            paragraph.append(trimmed)
        }
        // An unclosed fence runs to the end of the text.
        if let code { blocks.append(.code(code.joined(separator: "\n"))) } else { flush() }
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : .heading(hashes, title)
    }

    private static func bullet(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*", line.dropFirst().first == " " else { return nil }
        let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        let item = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }
}
