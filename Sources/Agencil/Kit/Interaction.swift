import AppKit
import SwiftUI

/// What every clickable thing does: the hand over its whole area, a lift on hover, a sink and dim while pressed.
/// `hit` is the clickable area (the whole rectangle unless the label is a circle or a capsule).
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var hit = AnyShape(Rectangle())
    var lift: Double = 0.12

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale, hit: hit, lift: lift)
    }
}

private struct PressBody: View {
    let configuration: ButtonStyle.Configuration
    let scale: CGFloat
    let hit: AnyShape
    let lift: Double
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .contentShape(hit)
            .overlay { hit.fill(Color.white.opacity(hovering && isEnabled && !pressed ? lift * 0.6 : 0)).allowsHitTesting(false) }
            .opacity(pressed ? 0.72 : 1)
            .scaleEffect(pressed ? scale : 1)
            .animation(Motion.snappy, value: pressed)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
            .pointingHandCursor(isEnabled)
    }
}

/// A row-wide button: a wash behind the whole row on hover, a deeper one while pressed.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowPressBody(configuration: configuration)
    }
}

private struct RowPressBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let wash = configuration.isPressed ? 0.10 : hovering ? 0.05 : 0.0
        configuration.label
            .contentShape(Rectangle())
            .background(Theme.wash.opacity(isEnabled ? wash : 0), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .animation(Motion.snappy, value: wash)
            .onHover { hovering = $0 }
            .pointingHandCursor(isEnabled)
    }
}

extension View {
    /// The hand over anything clickable. On macOS 15 SwiftUI owns the cursor; before that it is set on every move.
    @ViewBuilder
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(enabled ? .link : nil)
        } else {
            onContinuousHover { phase in
                guard enabled else { return }
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
    }
}

/// A text-only action ("Reset", "Turn on"): a padded target, so the hand covers more than the letters.
struct LinkButton: View {
    let title: String
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.house.meta).foregroundStyle(tint).lineLimit(1)
                .padding(.horizontal, Space.s).padding(.vertical, 5)
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}

/// The compact button for an action inside a row or card: a bordered capsule at the control height.
/// Destructive ones are a quiet red outline, the same weight as the plain ones; plain accent text is only for a
/// link that goes somewhere (`LinkButton`). `width` fixes the button so a column of them lines up.
struct ChipButton: View {
    let title: String
    var destructive = false
    var symbol: String?
    var width: CGFloat?
    let action: () -> Void

    var body: some View {
        let tint = destructive ? Theme.crit : Theme.textPrimary
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let symbol { Image(systemName: symbol).font(.house.badge) }
                Text(title).font(.house.control).lineLimit(1)
            }
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .frame(width: width, height: Size.control)
                .background(tint.opacity(destructive ? Theme.opacity.faint : Theme.opacity.wash), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(destructive ? 0.3 : 0.14), lineWidth: 0.5))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(PressStyle(scale: 0.96, hit: AnyShape(Capsule())))
    }
}
