import SwiftUI

/// A Markdown text drawn as formatted blocks: headings, bullet and numbered lists, fenced code and paragraphs, with
/// `**bold**` and `code` inside them. The only place block Markdown is drawn; a view that wants it uses this. The Kit
/// imports no logic, so the blocks arrive already parsed (the store maps `MarkdownDocument` into `Item`).
/// Everything wraps at the width it is given, and the text is selectable.
struct MarkdownBlock: View {
    enum Item: Equatable, Sendable {
        case heading(Int, String), paragraph(String), bullets([String]), numbered([String]), code(String)
    }

    /// An item with its inline markup already parsed, so a long text can be styled off the main actor.
    enum Styled: Sendable {
        case heading(Int, AttributedString), paragraph(AttributedString), bullets([AttributedString]), numbered([AttributedString])
        case code(Code)
    }

    /// A fenced block with its preview and line count worked out once, never while drawing.
    struct Code: Sendable {
        let full: String
        let preview: String
        let lines: Int

        init(_ full: String) {
            self.full = full
            preview = MarkdownBlock.codePreview(full)
            lines = full.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
    }

    let styled: [Styled]
    var color: Color = Theme.textPrimary

    init(items: [Item], color: Color = Theme.textPrimary) {
        self.init(styled: Self.style(items), color: color)
    }

    init(styled: [Styled], color: Color = Theme.textPrimary) {
        self.styled = styled
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(styled.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Styled) -> some View {
        switch block {
        case .heading(let level, let title):
            Text(title).font(level <= 2 ? .house.rowTitle : .house.control)
                .foregroundStyle(level <= 2 ? color : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, Space.xs)
        case .paragraph(let body):
            Text(body).font(.house.body).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            list(items) { _ in "\u{2022}" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .code(let body):
            CodeBlock(code: body)
        }
    }

    private func list(_ items: [AttributedString], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(marker(index)).font(.house.body).foregroundStyle(Theme.textTertiary).frame(minWidth: 14, alignment: .trailing)
                    Text(item).font(.house.body).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    nonisolated static func style(_ items: [Item]) -> [Styled] {
        items.map { item in
            switch item {
            case .heading(let level, let title): .heading(level, inline(title))
            case .paragraph(let body): .paragraph(inline(body))
            case .bullets(let items): .bullets(items.map(inline))
            case .numbered(let items): .numbered(items.map(inline))
            case .code(let body): .code(Code(body))
            }
        }
    }

    /// `**bold**`, `code` and links; a tag in the text stays text.
    private nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: literalUnderscores(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Agents write paths and names (`src/__tests__/a.ts`, `__init__`), not `_emphasis_`, so an underscore outside a
    /// code span is escaped and stays a character instead of turning the word bold.
    private nonisolated static func literalUnderscores(_ text: String) -> String {
        guard text.contains("_") else { return text }
        var out = ""
        var fence = 0 // the length of the open backtick run, 0 outside a code span
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`" {
                let end = text[index...].firstIndex { $0 != "`" } ?? text.endIndex
                let run = text.distance(from: index, to: end)
                if fence == 0 { fence = run } else if run == fence { fence = 0 }
                out += text[index..<end]
                index = end
                continue
            }
            if text[index] == "_" && fence == 0 { out += "\\_" } else { out.append(text[index]) }
            index = text.index(after: index)
        }
        return out
    }

    /// What a fenced block shows before it is opened: its first `Size.codePreviewLines` lines, at most
    /// `Size.codePreviewChars` characters, so one minified line cannot fill the panel either.
    nonisolated static func codePreview(_ code: String) -> String {
        // Splits only as far as the preview reaches, not the whole script.
        let lines = code.split(separator: "\n", maxSplits: Size.codePreviewLines, omittingEmptySubsequences: false)
        return String(lines.prefix(Size.codePreviewLines).joined(separator: "\n").prefix(Size.codePreviewChars))
    }
}

/// A fenced code block. A long one shows its preview and opens on demand, so a pasted script does not bury the prose
/// after it; the copy button always takes the whole code.
private struct CodeBlock: View {
    let code: MarkdownBlock.Code
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        let clamps = code.preview.count < code.full.count
        VStack(alignment: .leading, spacing: Space.s) {
            if clamps && !expanded {
                // One row per line, cut at the edge: a wrapped token reads as noise in a glance at the code.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(code.preview.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.house.mono).foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(code.full).font(.house.mono).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Space.s) {
                if clamps {
                    ChipButton(title: expanded ? "Show less" : "Show all \(code.lines) lines") { expanded.toggle() }
                }
                Spacer(minLength: 0)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy the code") {
                    Clipboard.copy(code.full)
                    copied = true
                }
            }
        }
        .padding(Space.m)
        .background(Theme.wash.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}
