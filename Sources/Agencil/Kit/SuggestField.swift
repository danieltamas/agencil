import SwiftUI

/// A text field that offers known values while the owner types. Any text may be typed; the list only helps, so a
/// value nobody knows is never refused here.
struct SuggestField: View {
    let placeholder: String
    @Binding var text: String
    let options: [String]
    var limit = 5

    private var matches: [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        if options.contains(text) { return [] }
        return options.filter { query.isEmpty || $0.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GlassField(placeholder: placeholder, text: $text, monospaced: true)
            let shown = Array(matches.prefix(limit))
            if !shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.self) { option in
                        Button { text = option } label: {
                            Text(option).font(.house.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                        }
                        .buttonStyle(RowPressStyle())
                    }
                    if matches.count > shown.count {
                        Text("\(matches.count - shown.count) more, keep typing to narrow").font(.house.meta).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                    }
                }
                .background(Theme.canvas.opacity(Theme.opacity.dim), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
    }
}
