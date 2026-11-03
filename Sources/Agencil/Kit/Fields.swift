import SwiftUI

/// The one surface every field wears: recessed, exactly `Size.control` tall, lit at the edge while `active`
/// (focused, or holding a choice). Search, text, secret and menu fields share it so a row of them reads as one line.
struct FieldCapsule: ViewModifier {
    var capsule = false
    let active: Bool

    func body(content: Content) -> some View {
        let shape = AnyShape(capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)))
        content
            .padding(.horizontal, 11)
            .frame(height: Size.control)
            .background(Theme.canvas.opacity(0.7), in: shape)
            .overlay(shape.stroke(active ? Theme.accent.opacity(Theme.opacity.ring) : Theme.hairline, lineWidth: active ? 1 : 0.5))
            .contentShape(shape)
    }
}

extension View {
    func fieldCapsule(active: Bool, capsule: Bool = false) -> some View {
        modifier(FieldCapsule(capsule: capsule, active: active))
    }
}

/// The lists' search: words from a title or a name. Escape or the cross clears it.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Theme.accent : Theme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.house.control)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Clear the search")
            }
        }
        .fieldCapsule(active: focused, capsule: true)
        .animation(Motion.snappy, value: focused)
    }
}

/// A text field on a recessed core, lit at the edge while focused.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .house.mono : .house.body)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .fieldCapsule(active: focused)
            .animation(Motion.snappy, value: focused)
    }
}

/// GlassField for a secret: the characters are never shown.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.house.body)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .fieldCapsule(active: focused)
            .animation(Motion.snappy, value: focused)
    }
}

/// A multi-line editor in the same recessed style.
struct GlassEditor: View {
    @Binding var text: String
    var monospaced = false
    var minHeight: CGFloat = 90
    /// A box that never grows past this height (the editor scrolls instead).
    var maxHeight: CGFloat?

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .house.mono : .house.body)
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(Space.m)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(Theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// A pop-up menu in the same recessed style, its current choice as the title. Long values (model ids) truncate in the middle.
struct MenuField: View {
    let title: String
    let options: [String]
    let pick: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in Button(option) { pick(option) } }
        } label: {
            HStack {
                Text(title).font(.house.body).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .fieldCapsule(active: hovering)
            .onHover { hovering = $0 }
            .pointingHandCursor()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

/// A labelled field: the label above, the control below, the same gap everywhere.
struct FieldBlock<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.house.control).foregroundStyle(Theme.textPrimary)
            control
            if let detail {
                Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
