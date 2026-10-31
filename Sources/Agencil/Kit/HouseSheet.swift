import SwiftUI

/// The one frame every sheet uses: a title, a line on what it does, the content, and a footer where the way out
/// is on the left of the main action, both on the right edge. Constructed only by `houseSheet`.
struct ModalFrame<Content: View>: View {
    let title: String
    var detail: String?
    var width = Size.modalWidth
    @ViewBuilder let content: Content
    var footer: ModalFooter

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.house.modalTitle).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(.house.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) { content }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            ModalFooterView(footer: footer)
        }
        .padding(Space.xxl)
        .frame(width: width)
        .frame(minHeight: 200, maxHeight: 640)
        .houseScheme()
    }
}

/// `secondary` (Cancel, Done) then `primary`, right-aligned in one row; the primary is the filled pill.
struct ModalFooter {
    struct Action {
        let title: String
        var disabled = false
        let run: () -> Void
    }

    var secondary: Action?
    var primary: Action?
}

private struct ModalFooterView: View {
    let footer: ModalFooter

    var body: some View {
        HStack(spacing: Space.l) {
            Spacer()
            if let secondary = footer.secondary {
                PillButton(title: secondary.title, symbol: "xmark", prominent: false, disabled: secondary.disabled, action: secondary.run)
            }
            if let primary = footer.primary {
                PillButton(title: primary.title, symbol: "checkmark", disabled: primary.disabled, action: primary.run)
            }
        }
    }
}

extension ModalFrame {
    /// A frame around a view that is already built, for renders that measure the real sheet content.
    init(title: String, detail: String? = nil, width: CGFloat = Size.modalWidth, content: Content, footer: ModalFooter) {
        self.title = title
        self.detail = detail
        self.width = width
        self.content = content
        self.footer = footer
    }

    init(title: String, detail: String? = nil, width: CGFloat = Size.modalWidth, footer: ModalFooter,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.width = width
        self.content = content()
        self.footer = footer
    }
}

extension View {
    /// The only sheet presenter: wraps the content in `ModalFrame` itself, so no view builds a frame of its own.
    func houseSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        detail: @escaping (Item) -> String? = { _ in nil },
        footer: @escaping (Item) -> ModalFooter,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item) { value in
            ModalFrameHost(title: title(value), detail: detail(value), footer: footer(value)) { content(value) }
        }
    }
}

private struct ModalFrameHost<Content: View>: View {
    let title: String
    let detail: String?
    let footer: ModalFooter
    @ViewBuilder let content: Content

    var body: some View {
        ModalFrame(title: title, detail: detail, footer: footer) { content }
    }
}
