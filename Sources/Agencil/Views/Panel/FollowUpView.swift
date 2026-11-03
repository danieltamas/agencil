import SwiftUI

/// What the owner asked the council's seats after it sat, and the field to ask the next thing (docs/U30-SPEC.md).
struct FollowUpView: View {
    let page: DetailPage
    let store: PanelStore

    var body: some View {
        if !page.followups.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Eyebrow(text: "Follow up")
                ForEach(page.followups) { followup in thread(followup) }
            }
        }
    }

    private func thread(_ followup: DetailPage.Followup) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                VendorMark(vendor: followup.vendor)
                Text(followup.seat).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
            }
            ForEach(Array(followup.turns.enumerated()), id: \.offset) { _, turn in
                HoverCard(accent: Theme.color(for: turn.tone), action: nil) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(turn.question).font(.house.control).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text(turn.meta).font(.house.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        MarkdownBlock(items: turn.items)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The box pinned under the sitting's page: a question for the whole council that held it, each of its seats answering on its own thread.
struct FollowUpComposer: View {
    let page: DetailPage
    let store: PanelStore

    var body: some View {
        if page.canFollowUp, let draft = store.followUp {
            VStack(alignment: .leading, spacing: Space.s) {
                Eyebrow(text: "Ask the council")
                if !draft.files.isEmpty {
                    FlowLayout {
                        ForEach(draft.files, id: \.self) { path in
                            AttachmentTile(name: (path as NSString).lastPathComponent, thumbnail: store.thumbnail(of: path)) { store.detachFromFollowUp(path) }
                        }
                    }
                }
                GlassEditor(text: Binding(get: { store.followUp?.text ?? "" }, set: { store.followUp?.text = $0 }),
                            minHeight: Size.followUpEditor, maxHeight: Size.followUpEditor)
                    .overlay(alignment: .bottomTrailing) {
                        AsyncPress(id: "followup:send", action: store.sendFollowUpAction()) { running, press in
                            PillButton(title: running ? "Asking..." : "Ask", symbol: "arrow.up.right", disabled: !store.canSendFollowUp || running, action: press)
                        }
                        .padding(Space.float)
                    }
                if let problem = store.followUpProblem { ProblemText(text: problem) }
            }
            .padding(.top, Space.m)
            .onPasteOfMedia { store.pasteIntoFollowUp() }
        }
    }
}
