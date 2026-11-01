import SwiftUI

/// A small capsule label. `filled` is for what is mine or needs me; `tinted` for the rest.
struct Chip: View {
    enum Style { case filled, tinted, outline, dashed }

    let text: String
    var symbol: String?
    var color: Color = Theme.unknown
    var style: Style = .tinted

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)) }
            Text(text).font(.house.badge).lineLimit(1)
        }
        // A control's label never wraps or truncates: the content around it yields instead.
        .fixedSize()
        .padding(.horizontal, Space.m)
        .frame(height: Size.chip)
        .foregroundStyle(style == .filled ? Theme.canvas : color)
        .background {
            switch style {
            case .filled: Capsule().fill(color)
            case .tinted: Capsule().fill(color.opacity(Theme.opacity.tint))
            case .outline: Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75)
            case .dashed: Capsule().strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2]))
            }
        }
    }
}

/// A microscopic uppercase label above a value or section.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.textTertiary

    var body: some View {
        Text(text.uppercased()).font(.house.eyebrow).tracking(1.4).foregroundStyle(color)
    }
}

/// A status glyph in its own tinted disc.
struct GlyphDisc: View {
    let symbol: String
    let color: Color
    var size: CGFloat = Size.iconButton

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }
}

/// A panel filter: an outlined capsule, tinted in the accent while it is the one in force.
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Chip(text: title, color: selected ? Theme.accent : Theme.textSecondary, style: selected ? .tinted : .outline)
        }
        .buttonStyle(PressStyle(scale: 0.97, hit: AnyShape(Capsule()), lift: 0.08))
    }
}
