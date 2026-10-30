import SwiftUI

/// What the "New ..." sheets create; the preview sheet shows the fields a real one validates.
struct NewObject: Identifiable {
    let kind: String
    var id: String { kind }
    var title: String { kind }
    var detail: String { "Saved to config.json; the broker picks it up without a restart." }
}

struct NewObjectForm: View {
    let object: NewObject
    @State private var name = ""
    @State private var harness = "codex"
    @State private var model = "gpt-5.5"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Name") { GlassField(placeholder: "reviewer-one", text: $name) }
            if name.isEmpty { ProblemText(text: "Give it a name, lowercase with dashes.") }
            FieldBlock(title: "Harness") { MenuField(title: harness, options: ["claude", "codex", "opencode", "hermes"]) { harness = $0 } }
            FieldBlock(title: "Model") { MenuField(title: model, options: ["gpt-5.5", "opus-5.5", "qwen3-coder"]) { model = $0 } }
        }
    }
}
