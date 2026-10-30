import AppKit
import SwiftUI

/// The pane's title block: an eyebrow in the pane's colour, the title, one line on what it does.
struct PaneHeader: View {
    let symbol: String
    let eyebrow: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Eyebrow(text: eyebrow, color: color)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
            Text(title).font(.house.paneTitle).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.house.body).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// The grid every pane follows: rows keep a fixed height, the control sits on the right edge, and the pieces of a
/// control (field, unit, reset) have the same widths in every row, so their edges line up down the card.
enum SettingsMetrics {
    static let rowInset: CGFloat = 8
    static let rowHeight = Size.settingsRow
    static let fieldWidth: CGFloat = 84
    static let unitWidth: CGFloat = 168
    static let resetWidth: CGFloat = 52
}

/// A name on the left, its control on the right, on one baseline-centred line.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.house.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: Space.l)
            control
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

/// A hairline between the rows of one card.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
}

/// One setting: its name and why it matters on the left of the card, the control below.
struct SettingsCard<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                    if let detail { Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary) }
                }
                VStack(alignment: .leading, spacing: Space.s) { content }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A choice among a few values, the chosen one lit. Control height.
struct SegmentChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.house.control).monospacedDigit()
                .foregroundStyle(selected ? Theme.canvas : Theme.textSecondary)
                .padding(.horizontal, Space.l)
                .frame(height: Size.control)
                .background {
                    if selected { Capsule().fill(Theme.brand) } else { Capsule().fill(Theme.wash.opacity(Theme.opacity.wash)) }
                }
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(hit: AnyShape(Capsule()), lift: 0.08))
    }
}

/// An on/off setting: the label on the left, the switch on the right, and the whole row is the button.
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(Motion.snappy) { isOn.toggle() } } label: {
            HStack(spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(.house.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let detail { Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary) }
                }
                Spacer(minLength: Space.l)
                SwitchTrack(isOn: isOn)
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .frame(minHeight: SettingsMetrics.rowHeight)
        }
        .buttonStyle(RowPressStyle())
        .padding(.horizontal, -SettingsMetrics.rowInset)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct SwitchTrack: View {
    let isOn: Bool

    var body: some View {
        Capsule().fill(isOn ? Theme.accent : Theme.wash.opacity(0.18))
            .frame(width: 34, height: 20)
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(isOn ? Theme.canvas : Theme.textSecondary).frame(width: 14, height: 14).padding(3)
            }
    }
}

struct ProblemText: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .medium))
            Text(text).font(.house.meta).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.crit)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// A step's result line: the outcome in its signal colour; the fix hint below it in the secondary colour.
struct StatusLine: View {
    let text: String
    var signal: Signal?
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(text).font(.house.control).foregroundStyle(signal.map(Theme.color(for:)) ?? Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint).font(.house.meta).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

/// Copies a command; the glyph turns into a check for a moment so the press never looks like nothing happened.
struct CopyButton: View {
    let text: String
    let help: String
    @State private var copied = false
    /// The pending reset, cancelled by a new press so the check always stays the full time.
    @State private var reset: Task<Void, Never>?

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : help,
                   tint: copied ? Theme.ok : Theme.textSecondary) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Motion.snappy) { copied = true }
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.snappy) { copied = false }
            }
        }
    }
}
