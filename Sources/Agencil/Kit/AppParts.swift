import AppKit
import SwiftUI

/// A small outlined link; the arrow says it leaves the app.
struct LinkChip: View {
    let title: String
    var symbol = "arrow.up.right"
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    init(title: String, url: URL) {
        self.title = title
        help = url.absoluteString
        action = { NSWorkspace.shared.open(url) }
    }

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Chip(text: title, symbol: symbol, color: hovering ? Theme.textPrimary : Theme.textSecondary, style: .outline)
        }
        .buttonStyle(PressStyle(scale: 0.95, hit: AnyShape(Capsule()), lift: 0))
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(help ?? title)
    }
}

/// The install command in a well, with a copy button that answers the press.
struct InstallLine: View {
    let command: String

    var body: some View {
        HStack(spacing: Space.s) {
            Text("$").font(.house.mono).foregroundStyle(Theme.textTertiary)
            Text(command).font(.house.mono).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: Space.s)
            CopyButton(text: command, help: "Copy the install command")
        }
        .padding(.leading, Space.m).padding(.trailing, Space.xxs).padding(.vertical, Space.xxs)
        .background(Theme.wash.opacity(Theme.opacity.faint), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// What Agencil shows while it does something it cannot measure: a line of text and the system's moving bar, which
/// exists only while the operation runs.
struct OperationProgress: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(text).font(.house.meta).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Theme.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An app's icon in a glow of its hue. A full-bleed mark is inset and rounded to sit beside the macOS-shaped ones.
struct AppIconTile: View {
    let image: NSImage
    let fullBleed: Bool
    let glow: Color
    let size: CGFloat

    private static let fullBleedInset = 0.1
    private static let macCorner = 0.225

    var body: some View {
        let inset = fullBleed ? size * Self.fullBleedInset : 0
        let corner = (size - inset * 2) * Self.macCorner
        Image(nsImage: image).resizable().interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: fullBleed ? corner : 0, style: .continuous))
            .padding(inset)
            .frame(width: size, height: size)
            .shadow(color: glow.opacity(Theme.opacity.ring), radius: Space.l, y: Space.xs)
    }
}
