import AppKit
import SwiftUI

/// The cost text of the Costs pane: dollars, two to four decimals, digits that do not shift as they change.
struct Money: View {
    let value: Decimal
    var font = Font.house.control

    /// The same text as a string, for a caption.
    static func text(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...4)).locale(Locale(identifier: "en_US")))
    }

    var body: some View {
        Text(Self.text(value))
            .font(font).monospacedDigit().foregroundStyle(Theme.textPrimary)
    }
}

/// A capsule meter: how much of the whole one row is. Fixed height, so rows never change it.
struct ShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Theme.wash.opacity(Theme.opacity.wash))
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.brand).frame(width: max(Size.shareBarMin, proxy.size.width * min(max(share, 0), 1)))
                }
        }
        .frame(height: Size.shareBar)
    }
}

/// One bar per day, scaled to the dearest, every bar a button. The strip's height never changes with the data.
struct BarStrip: View {
    struct Bar: Identifiable, Hashable {
        let id: String
        /// 0...1 of the strip's height.
        let share: Double
        let today: Bool
        let lit: Bool
        /// False for a day nothing ran: drawn faint.
        let filled: Bool
        let help: String
    }

    let bars: [Bar]
    let onSelect: (Int) -> Void
    var onHover: (Int?) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.xxs) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                Button { onSelect(index) } label: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: Radius.bezel, style: .continuous)
                            .fill(fill(bar))
                            .frame(height: max(Size.barMin, Size.barStrip * min(max(bar.share, 0), 1)))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in withAnimation(Motion.snappy) { onHover(inside ? index : nil) } }
                .help(bar.help)
            }
        }
        .frame(height: Size.barStrip)
    }

    private func fill(_ bar: Bar) -> AnyShapeStyle {
        if bar.lit { return AnyShapeStyle(Theme.brand) }
        if bar.today { return AnyShapeStyle(Theme.ok) }
        return AnyShapeStyle(Theme.accent.opacity(bar.filled ? Theme.opacity.dim : Theme.opacity.tint))
    }
}

/// Wraps its children onto as many lines as the width needs; each line is as tall as its tallest child.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Offered no width, it wraps at a paragraph's width, so a row of chips never sets the natural width of its pane.
        arrange(width: proposal.width ?? Size.paragraph, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: min(widest, width.isFinite ? width : widest), height: y + line), origins)
    }
}

/// One attached file as a tile: the picture itself for an image, a document glyph and the name for anything else, and a remove control.
struct AttachmentTile: View {
    let name: String
    let thumbnail: NSImage?
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    VStack(spacing: Space.xxs) {
                        Image(systemName: "doc").font(.house.rowTitle).foregroundStyle(Theme.textSecondary)
                        Text(name).font(.house.eyebrow).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(Space.xs)
                }
            }
            .frame(width: Size.attachment, height: Size.attachment)
            .background(Theme.canvas.opacity(Theme.opacity.dim), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Button(action: remove) {
                Image(systemName: "xmark").font(.house.eyebrow).foregroundStyle(Theme.textPrimary).padding(Space.xs)
                    .background(Theme.canvas.opacity(Theme.opacity.dim), in: Circle())
            }
            .buttonStyle(.plain).padding(Space.xxs).accessibilityLabel("Remove \(name)")
        }
        .help(name)
    }
}
