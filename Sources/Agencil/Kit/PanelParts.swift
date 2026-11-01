import SwiftUI

/// The brand glyph in the panel header.
struct BrandGlyph: View {
    var body: some View {
        Image(systemName: "circle.hexagongrid.fill").font(.system(size: Size.menuBarGlyph - 4)).foregroundStyle(Theme.brand)
    }
}

/// The small arrow between a caller and its target.
struct ArrowGlyph: View {
    var body: some View { Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary) }
}

extension View {
    /// A row title: up to two lines before it truncates.
    func metaStrong() -> some View { font(.house.metaStrong) }
    func titleLines() -> some View { lineLimit(2) }
    func panelHeaderInsets() -> some View { padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)) }
    func panelFooterInsets() -> some View {
        padding(.horizontal, Space.panelInset).padding(.vertical, 10)
            .overlay(alignment: .top) { RowDivider() }
    }
    /// The pane swaps with the spring fade, keyed by its id.
    func paneSwap<Key: Equatable>(_ key: Key) -> some View { animation(Motion.snappy, value: key) }
    func sidebarWash() -> some View { background(Theme.canvas.opacity(0.55)) }
}

/// A pane's colour: a signal or one of the council hues, never a free colour.
struct PaneTint {
    var signal: Signal?
    var hue: Int?
    static let accent = PaneTint()
    static let cool = PaneTint(hue: 4)
    static let rose = PaneTint(hue: 3)
    static let good = PaneTint(signal: .ok)
    static let caution = PaneTint(signal: .warn)
    static let quiet = PaneTint(signal: .unknown)

    @MainActor var color: Color {
        if let signal { return Theme.color(for: signal) }
        if let hue { return Theme.councilHue(hue) }
        return Theme.accent
    }
}

/// One row of the Settings sidebar: a glyph tile in the pane's colour and the pane's name.
struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: PaneTint
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint.color)
                    .frame(width: Size.sidebarGlyph, height: Size.sidebarGlyph)
                    .background(tint.color.opacity(selected ? Theme.opacity.lift : Theme.opacity.wash),
                                in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                Text(title).font(.house.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.m).frame(height: Size.settingsRow)
            .background {
                if selected {
                    let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    shape.fill(Theme.core).overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
