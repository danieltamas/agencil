import AgencilCore
import Foundation

/// The Add model sheet: adding, editing and deleting the owner's own models. Every write goes through `ConfigEditor`,
/// which re-reads the file first; a refusal stays in `problems` and the sheet stays open.
extension ModelCatalogStore {
    var formTitle: String { editing == nil ? "Add model" : "Edit model" }

    func startAdd() {
        open(Form(), editing: nil)
    }

    /// Opens the sheet for the custom model with this id, filled from the file as it is now. A file that cannot be
    /// read opens nothing; `reload` puts its reason on the pane.
    func startEdit(_ id: String) {
        guard let editor else { return }
        do {
            guard let model = try editor.customModels().first(where: { $0.id == id }) else { return }
            open(Form(id: model.id, harness: model.harness, note: model.note), editing: model)
        } catch {
            reload()
        }
    }

    private func open(_ next: Form, editing model: CustomModel?) {
        form = next
        editing = model
        problems = [:]
        confirmingDelete = false
        presenting = .model
    }

    /// True when the model was saved; otherwise `problems` says which field to fix.
    func save() -> Bool {
        guard let editor else {
            problems = ["form": "Settings are not connected to a config in this view."]
            return false
        }
        let model = CustomModel(id: form.id.trimmingCharacters(in: .whitespaces), harness: form.harness,
                                note: form.note.trimmingCharacters(in: .whitespaces))
        do {
            if let old = editing { try editor.update(customModel: old, with: model) } else { try editor.add(customModel: model) }
        } catch let refused as SheetProblems {
            problems = refused.fields
            return false
        } catch {
            problems = ["form": error.localizedDescription]
            return false
        }
        reload()
        return true
    }

    func deleteAction() -> () async -> Void {
        { [self] in delete() }
    }

    private func delete() {
        guard let editor, let model = editing else { return }
        do { try editor.remove(customModel: model) } catch {
            problems = (error as? SheetProblems)?.fields ?? ["form": error.localizedDescription]
            confirmingDelete = false
            return
        }
        confirmingDelete = false
        reload()
        presenting = nil
    }
}
