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
            Text(detail).font(.house.body).foregroundStyle(Theme.textSecondary).paragraph()
        }
    }
}

/// The grid every pane follows: rows keep a fixed height, the control sits on the right edge, and the pieces of a
/// control (field, unit, reset) have the same widths in every row, so their edges line up down the card.
enum SettingsMetrics {
    static let rowInset: CGFloat = 8
    static let rowHeight = Size.settingsRow
    static let fieldWidth: CGFloat = 84
    static let wideFieldWidth: CGFloat = 168
    static let unitWidth: CGFloat = 168
    static let resetWidth: CGFloat = 52
    /// A status row's trailing columns: the badge, then the button, the same in every row of a card.
    static let statusWidth: CGFloat = 96
    static let actionWidth: CGFloat = 92
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

/// A row that opens something: the whole row is the button, with a wash and the hand on hover.
struct PressRow<Content: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) { content.padding(.horizontal, SettingsMetrics.rowInset) }
            .buttonStyle(RowPressStyle())
            .padding(.horizontal, -SettingsMetrics.rowInset)
            .accessibilityLabel(label)
    }
}

/// A hairline between the rows of one card.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
}

/// One setting: its name and why it matters on the left of the card, the control below.
/// `mark` puts a vendor's mark before the title, `accessory` a chip or two at the trailing edge of the header.
struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String
    var detail: String?
    var mark: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(title: String, detail: String? = nil, mark: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.mark = mark
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.s) {
                        if let mark { VendorMark(vendor: mark) }
                        Text(title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: Space.s)
                        accessory
                    }
                    if let detail { Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph() }
                }
                VStack(alignment: .leading, spacing: Space.s) { content }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(title: String, detail: String? = nil, mark: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, mark: mark, accessory: { EmptyView() }, content: content)
    }
}

/// A step of a card: its name and where it lives on the left, then a badge column and a button column of fixed
/// widths, so every row of the card ends in the same two edges.
struct StatusRow<Action: View>: View {
    let title: String
    let detail: String
    let status: String
    let color: Color
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.house.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle).help(detail)
            }
            Spacer(minLength: Space.s)
            Chip(text: status, color: color)
                .frame(width: SettingsMetrics.statusWidth, alignment: .leading)
            action.frame(width: SettingsMetrics.actionWidth, alignment: .trailing)
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// The fields of a server entry as mono key and value lines in a recessed well; values are selectable.
struct EntryLines: View {
    struct Field { let key: String; let value: String }

    let fields: [Field]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.l, verticalSpacing: Space.xxs) {
            ForEach(fields, id: \.key) { field in
                GridRow {
                    Text(field.key).font(.house.mono).foregroundStyle(Theme.textTertiary)
                    Text(field.value).font(.house.mono).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.wash.opacity(Theme.opacity.faint), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
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
