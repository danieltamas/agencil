import SwiftUI

/// A tile that can be dragged onto a `DropCard` by its string payload, or pressed to do the same: drag is never the
/// only way. `selected` draws the accent rail; `dimmed` greys a tile that cannot be used yet.
struct DropTile<Content: View>: View {
    let payload: String
    var selected = false
    var dimmed = false
    let action: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        HoverCard(accent: selected ? Theme.accent : nil, action: dimmed ? nil : action) { content }
            .opacity(dimmed ? Theme.opacity.dim : 1)
            .draggable(payload) {
                // The drag preview is the payload's name, so the tile itself stays put and readable.
                Chip(text: payload, color: Theme.accent, style: .filled)
            }
            .disabled(dimmed)
    }
}

/// A card that takes `DropTile` payloads: its border lights while a tile hovers over it. `accept` gets each dropped
/// payload; the store decides what it means (a council member, a route caller).
struct DropCard<Content: View>: View {
    let title: String
    var detail: String?
    let accept: (String) -> Void
    @ViewBuilder let content: Content
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
            if let detail {
                Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.core, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: targeted ? 1.5 : 0.75, dash: targeted ? [] : [4, 3]))
        }
        .dropDestination(for: String.self) { items, _ in
            items.forEach(accept)
            return !items.isEmpty
        } isTargeted: { targeted = $0 }
        .animation(Motion.snappy, value: targeted)
    }
}
