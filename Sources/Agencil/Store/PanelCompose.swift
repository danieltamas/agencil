import AgencilCore
import AppKit
import Foundation

/// What the owner has typed into the manual sitting form (docs/U27-SPEC.md).
struct SittingDraft: Equatable {
    static let kinds = ["question", "design", "plan", "code", "docs", "other"]
    static let fileLimit = 8

    var council = ""
    var kind = "question"
    var question = ""
    var repo = ""
    var diff = ""
    var files: [String] = []

    var isCode: Bool { kind == "code" }

    /// A council, a question, and for code the repo and diff range the broker will insist on.
    var isComplete: Bool {
        func filled(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filled(council) && filled(question) && (!isCode || (filled(repo) && filled(diff)))
    }
}

extension PanelStore {
    var canStartSitting: Bool { compose?.isComplete == true && !starting }

    /// Opens a fresh form with the councils the broker knows.
    func newSitting() async {
        guard let send = brokerRequest, !starting else { return }
        do {
            let reply = try await send(["op": "councils", "caller": "owner"])
            councilNames = (reply["councils"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            compose = SittingDraft()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func newSittingAction() -> () async -> Void { { [self] in await newSitting() } }

    /// Back does nothing while a Start is in flight: its completion would otherwise land on a different form.
    func closeCompose() {
        guard !starting else { return }
        discardPasted(compose?.files ?? [])
        compose = nil
        composeProblem = nil
    }

    /// Wakes the chosen council as the owner. The detail page of the new sitting replaces the form and fills in as
    /// rounds finish; a refusal leaves the form as it was and says why.
    func startSitting() async {
        guard let draft = compose, draft.isComplete, !starting, let send = brokerRequest else { return }
        starting = true
        composeProblem = nil
        defer { starting = false }
        var request: [String: Any] = [
            "op": "wake", "caller": "owner", "council": draft.council, "change_kind": draft.kind,
            "question": draft.question.trimmingCharacters(in: .whitespacesAndNewlines), "wait_seconds": 0,
        ]
        if !draft.files.isEmpty { request["files"] = draft.files }
        if draft.isCode { request["repo"] = draft.repo; request["diff"] = draft.diff }
        do {
            let reply = try await send(request)
            guard let id = reply["sitting"] as? String else {
                fail(reply["error"] as? String ?? "the broker did not name the sitting")
                return
            }
            discardPasted(draft.files)
            compose = nil
            problem = nil
            present(DetailPage.started(id: id, question: draft.question))
            await refresh()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// The refusal stays in the form until the next try; the footer line carries it too.
    private func fail(_ message: String) {
        composeProblem = message
        problem = message
    }

    func startSittingAction() -> () async -> Void { { [self] in await startSitting() } }
}

extension DetailPage {
    /// A sitting the owner has just woken: it is live and its record is on the way.
    static func started(id: String, question: String) -> DetailPage {
        let title = question.split(separator: "\n").first.map(String.init) ?? question
        var page = DetailPage(id: id, kind: .sitting, title: title, state: "Sitting", tone: PanelTone.signal(state: "running"), live: true)
        page.loading = true
        return page
    }
}

extension PanelStore {
    /// Adds picked files to the form: each once, at most `SittingDraft.fileLimit` in all.
    func attachFiles(_ paths: [String]) {
        guard var draft = compose else { return }
        for path in paths where !draft.files.contains(path) && draft.files.count < SittingDraft.fileLimit { draft.files.append(path) }
        compose = draft
    }

    func detachFile(_ path: String) {
        discardPasted([path])
        compose?.files.removeAll { $0 == path }
    }
}

extension PanelStore {
    /// Where pasted images are kept until a sitting starts: private to the owner (docs/U28-SPEC.md).
    private var attachments: URL {
        (attachmentsRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("agencil-home")).appendingPathComponent("attachments")
    }

    /// Whether the form saved this file itself (a pasted image), as opposed to one the owner picked.
    func isPasted(_ path: String) -> Bool { pastedFiles.contains(path) }

    /// Adds a copied image to the form as a PNG file of its own: any image format the system reads, one PNG out.
    func attachImage(_ data: Data) {
        guard var draft = compose else { return }
        guard draft.files.count < SittingDraft.fileLimit else {
            composeProblem = "at most \(SittingDraft.fileLimit) files"
            return
        }
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            composeProblem = "that is not an image"
            return
        }
        do {
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = attachments.appendingPathComponent(UUID().uuidString + ".png")
            guard FileManager.default.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
                composeProblem = "could not save the image"
                return
            }
            draft.files.append(url.path)
            pastedFiles.insert(url.path)
            compose = draft
            composeProblem = nil
        } catch {
            composeProblem = error.localizedDescription
        }
    }

    /// The Paste image chip and Cmd-V: whatever image the clipboard holds.
    func pasteImage() {
        guard let data = Clipboard.imageData() else {
            composeProblem = "the clipboard holds no image"
            return
        }
        attachImage(data)
    }

    private func discardPasted(_ paths: [String]) {
        for path in paths where pastedFiles.remove(path) != nil { try? FileManager.default.removeItem(atPath: path) }
    }
}
