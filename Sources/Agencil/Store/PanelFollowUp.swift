import AppKit
import Foundation

/// What the owner has typed to ask one seat of a finished sitting more (docs/U30-SPEC.md).
struct FollowUpDraft: Equatable {
    var seat: String
    var text: String
    /// Absolute paths of what is attached: files the owner picked or dropped, and images saved from the clipboard.
    var files: [String] = []
    static let fileLimit = 8
}

extension PanelStore {
    /// The open sitting's draft; nil until its detail has loaded and a seat can be asked.
    var followUp: FollowUpDraft? {
        get { detail.flatMap { followUpDrafts[$0.id] } }
        set { if let id = detail?.id { followUpDrafts[id] = newValue } }
    }

    var canSendFollowUp: Bool {
        guard let draft = followUp, detail?.canFollowUp == true, !followingUp else { return false }
        return !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Opens a draft for a sitting that can be asked, aimed at the broker's default seat; a draft keeps what was typed and
    /// the seat picked, unless that seat is no longer one the council offers.
    func syncFollowUpDraft() {
        guard let page = detail, page.kind == .sitting, page.canFollowUp else { return }
        let fallback = page.followUpDefault ?? page.followUpSeats.first ?? ""
        var draft = followUpDrafts[page.id] ?? FollowUpDraft(seat: fallback, text: "")
        if !page.followUpSeats.contains(draft.seat) { draft.seat = fallback }
        if followUpDrafts[page.id] != draft { followUpDrafts[page.id] = draft }
    }

    func sendFollowUp() async {
        guard canSendFollowUp, let page = detail, let draft = followUp, let send = brokerRequest else { return }
        followingUp = true
        followUpProblem = nil
        defer { followingUp = false }
        let request: [String: Any] = ["op": "followup", "caller": "owner", "sitting": page.id, "council": true,
                                      "question": draft.text.trimmingCharacters(in: .whitespacesAndNewlines), "files": draft.files]
        do {
            _ = try await send(request)
            // What was sent is gone from the field; anything typed while it was on its way stays.
            if followUpDrafts[page.id]?.text == draft.text { followUpDrafts[page.id]?.text = "" }
            // The broker read the files before it answered: they are no longer needed here.
            discardPasted(draft.files)
            followUpDrafts[page.id]?.files.removeAll { draft.files.contains($0) }
            await loadDetail()
        } catch {
            followUpProblem = error.localizedDescription
        }
    }

    func sendFollowUpAction() -> () async -> Void { { [self] in await sendFollowUp() } }
}

extension PanelStore {
    /// Cmd-V in the follow-up box: the images and the files the clipboard holds, each added as its own tile.
    func pasteIntoFollowUp() {
        var added = false
        for path in Clipboard.filePaths() { added = attachToFollowUp(path: path) || added }
        if !added, let data = Clipboard.imageData() {
            do { attachToFollowUp(path: try savePastedImage(data)) } catch { followUpProblem = error.localizedDescription }
        }
    }

    func attachToFollowUp(paths: [String]) { for path in paths { attachToFollowUp(path: path) } }

    @discardableResult private func attachToFollowUp(path: String) -> Bool {
        guard var draft = followUp, !draft.files.contains(path) else { return false }
        guard draft.files.count < FollowUpDraft.fileLimit else {
            followUpProblem = "at most \(FollowUpDraft.fileLimit) files"
            return false
        }
        draft.files.append(path)
        followUp = draft
        followUpProblem = nil
        return true
    }

    func detachFromFollowUp(_ path: String) {
        discardPasted([path])
        followUp?.files.removeAll { $0 == path }
    }

    func thumbnail(of path: String) -> NSImage? { NSImage(contentsOfFile: path) }
}
