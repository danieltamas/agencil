import SwiftUI

/// A Markdown text drawn as formatted blocks: headings, bullet and numbered lists, fenced code and paragraphs, with
/// `**bold**` and `code` inside them. The only place block Markdown is drawn; a view that wants it uses this. The Kit
/// imports no logic, so the blocks arrive already parsed (the store maps `MarkdownDocument` into `Item`).
/// Everything wraps at the width it is given, and the text is selectable.
struct MarkdownBlock: View {
    enum Item: Equatable {
        case heading(Int, String), paragraph(String), bullets([String]), numbered([String]), code(String)
    }

    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Item) -> some View {
        switch block {
        case .heading(let level, let title):
            Text(inline(title)).font(level <= 2 ? .house.rowTitle : .house.control)
                .foregroundStyle(level <= 2 ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, Space.xs)
        case .paragraph(let body):
            Text(inline(body)).font(.house.body).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            list(items) { _ in "\u{2022}" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .code(let body):
            Text(body).font(.house.mono).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.wash.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(marker(index)).font(.house.body).foregroundStyle(Theme.textTertiary).frame(minWidth: 14, alignment: .trailing)
                    Text(inline(item)).font(.house.body).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// `**bold**`, `code` and links; a tag in the text stays text.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
