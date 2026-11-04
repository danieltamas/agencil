import SwiftUI

/// A seat's answer or a record section, which can run to many thousands of characters, drawn as Markdown. It shows
/// about `Size.longTextChars` of it and opens on demand; a fenced block counts only its preview, so the prose after a
/// long script still shows. The text is parsed and styled off the main actor, once per text and state, so opening a
/// big sitting does not stall the panel. The Kit imports no logic: the caller hands in the parser.
struct LongText: View {
    let text: String
    var color: Color = Theme.textPrimary
    let blocks: @Sendable (String) -> [MarkdownBlock.Item]
    @State private var expanded = false
    /// The styled blocks with the text they were made from, so a result for a text no longer shown is never drawn.
    @State private var prepared: (source: String, styled: [MarkdownBlock.Styled], clipped: Bool)?

    private struct Key: Equatable { let text: String, expanded: Bool }

    var body: some View {
        let current = prepared?.source == text ? prepared : nil
        VStack(alignment: .leading, spacing: Space.xs) {
            MarkdownBlock(styled: current?.styled ?? Self.placeholder(text), color: color)
            if expanded || current?.clipped == true {
                ChipButton(title: expanded ? "Show less" : "Show the full text (\(text.count) characters)") { expanded.toggle() }
            }
        }
        .task(id: Key(text: text, expanded: expanded)) {
            let source = text, open = expanded, parse = blocks
            // Off the main actor: parsing and styling a long answer is the slow part.
            let result = await Task.detached(priority: .userInitiated) {
                let items = parse(source)
                let shown = open ? items : Self.budgeted(items)
                return (MarkdownBlock.style(shown), shown != items)
            }.value
            guard !Task.isCancelled, source == text else { return }
            prepared = (source, result.0, result.1)
        }
    }

    /// What shows for the moment before the parse lands: the opening prose only, never raw fences or a wall of text.
    private static func placeholder(_ text: String) -> [MarkdownBlock.Styled] {
        let prose = text.range(of: "```").map { String(text[..<$0.lowerBound]) } ?? text
        let opening = prose.prefix(Size.placeholderChars).trimmingCharacters(in: .whitespacesAndNewlines)
        return opening.isEmpty ? [] : [.paragraph(AttributedString(opening))]
    }

    /// The leading blocks that fit `Size.longTextChars`; the text, heading or list item that crosses the line is cut
    /// there, and a code block counts only the preview it shows.
    nonisolated static func budgeted(_ items: [MarkdownBlock.Item]) -> [MarkdownBlock.Item] {
        var left = Size.longTextChars
        var kept: [MarkdownBlock.Item] = []

        func take(_ text: String) -> String {
            defer { left -= min(left, text.count) }
            return text.count <= left ? text : String(text.prefix(left)) + "..."
        }
        func takeList(_ list: [String]) -> [String] {
            var taken: [String] = []
            for entry in list where left > 0 { taken.append(take(entry)) }
            return taken
        }

        for item in items {
            guard left > 0 else { break }
            switch item {
            case .heading(let level, let title): kept.append(.heading(level, take(title)))
            case .paragraph(let body): kept.append(.paragraph(take(body)))
            case .bullets(let list): kept.append(.bullets(takeList(list)))
            case .numbered(let list): kept.append(.numbered(takeList(list)))
            case .code(let body):
                // The preview is already bounded, so the first block always shows; a later one waits for the full text.
                let cost = MarkdownBlock.codePreview(body).count
                guard cost <= left || kept.isEmpty else { left = 0; break }
                kept.append(item)
                left -= min(left, cost)
            }
        }
        return kept
    }
}
