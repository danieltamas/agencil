import SwiftUI

/// The manual sitting form, pushed in the panel like a detail page: pick a council and a kind, ask the question,
/// attach files, Start. The sitting's own detail page replaces it and carries the structured answer.
struct ComposeView: View {
    let store: PanelStore

    private func field(_ keyPath: WritableKeyPath<SittingDraft, String>) -> Binding<String> {
        Binding(get: { store.compose?[keyPath: keyPath] ?? "" }, set: { store.compose?[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                ChipButton(title: "Back", symbol: "chevron.left", action: store.closeCompose)
                Spacer(minLength: 0)
            }
            Text("New sitting").font(.house.header).foregroundStyle(Theme.textPrimary)
            if store.councilNames.isEmpty {
                EmptyState(symbol: "circle.hexagongrid", title: "No council configured", detail: "Add a council in Settings, then start a sitting here.")
                    .frame(maxHeight: .infinity)
            } else {
                form
                if let problem = store.composeProblem { ProblemText(text: problem) }
                AsyncPress(id: "sitting:start", action: store.startSittingAction()) { running, press in
                    PillButton(title: running ? "Starting..." : "Start", symbol: "arrow.up.right", disabled: !store.canStartSitting || running, action: press)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// A pasted image has no name worth showing; a picked file keeps its own.
    private func label(_ path: String, index: Int) -> String {
        guard store.isPasted(path) else { return (path as NSString).lastPathComponent }
        let before = (store.compose?.files ?? []).prefix(index).filter(store.isPasted).count
        return "Pasted image \(before + 1)"
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                FieldBlock(title: "Council") {
                    MenuField(title: store.compose?.council.isEmpty == false ? store.compose?.council ?? "" : "Choose a council",
                              options: store.councilNames) { store.compose?.council = $0 }
                }
                FieldBlock(title: "Kind") {
                    MenuField(title: store.compose?.kind ?? "", options: SittingDraft.kinds) { store.compose?.kind = $0 }
                }
                FieldBlock(title: "Question") { GlassEditor(text: field(\.question)) }
                if store.compose?.isCode == true {
                    FieldBlock(title: "Repo", detail: "The checkout the seats read.") { GlassField(placeholder: "/path/to/repo", text: field(\.repo), monospaced: true) }
                    FieldBlock(title: "Diff range") { GlassField(placeholder: "main..HEAD", text: field(\.diff), monospaced: true) }
                }
                FieldBlock(title: "Files", detail: "Up to \(SittingDraft.fileLimit). Each is read once and sent to every seat as evidence.") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(Array((store.compose?.files ?? []).enumerated()), id: \.element) { index, path in
                            HStack(spacing: Space.m) {
                                Image(systemName: store.isPasted(path) ? "photo" : "doc").font(.house.badge).foregroundStyle(Theme.textTertiary)
                                Text(label(path, index: index)).font(.house.meta).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                IconButton(symbol: "xmark", help: "Remove \(label(path, index: index))") { store.detachFile(path) }
                            }
                        }
                        if (store.compose?.files.count ?? 0) < SittingDraft.fileLimit {
                            HStack(spacing: Space.m) {
                                ChipButton(title: "Attach files", symbol: "paperclip") { store.attachFiles(FilePicker.choose(limit: SittingDraft.fileLimit)) }
                                ChipButton(title: "Paste image", symbol: "photo.on.rectangle", action: store.pasteImage)
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .onPasteCommand(of: [.image]) { _ in store.pasteImage() }
    }
}
