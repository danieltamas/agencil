import SwiftUI

/// A seat's answer or a record section, which can run to many thousands of characters. It shows the first
/// `Size.longTextChars` and opens on demand, and parses its inline markdown once per shown text instead of on every
/// redraw, so opening a big sitting does not stall the panel.
struct LongText: View {
    let text: String
    var color: Color = Theme.textPrimary
    @State private var expanded = false
    /// The parsed text with the source it was parsed from, so a result for text no longer shown is never drawn.
    @State private var parsed: (source: String, value: AttributedString)?

    private var shown: String { expanded || text.count <= Size.longTextChars ? text : String(text.prefix(Size.longTextChars)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(parsed?.source == shown ? parsed!.value : AttributedString(shown)).font(.house.body).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if text.count > Size.longTextChars {
                ChipButton(title: expanded ? "Show less" : "Show the full text (\(text.count) characters)") { expanded.toggle() }
            }
        }
        .task(id: shown) {
            let source = shown
            // Off the main actor: parsing a long answer is the slow part.
            let result = await Task.detached(priority: .userInitiated) { Self.styled(source) }.value
            guard !Task.isCancelled, source == shown else { return }
            parsed = (source, result)
        }
    }

    /// Answers are mostly prose with the odd `code` or **bold**; inline markdown, whitespace kept.
    nonisolated static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
