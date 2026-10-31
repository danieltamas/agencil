import SwiftUI

/// The fields of the three "New ..." sheets. Each problem the store reports shows under its own field; one the
/// store cannot place shows at the foot under `form`.
struct NewObjectForm: View {
    @Bindable var store: SettingsStore
    let kind: SheetKind
    let problems: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            switch kind {
            case .seat: seat
            case .council: council
            case .route: route
            }
            problem("form")
        }
    }

    @ViewBuilder private func problem(_ key: String) -> some View {
        if let text = problems[key] { ProblemText(text: text) }
    }

    private var seat: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Name") { GlassField(placeholder: "reviewer-one", text: $store.seatForm.name) }
            problem("name")
            FieldBlock(title: "Harness") {
                MenuField(title: store.seatForm.harness, options: ["claude", "codex", "opencode", "hermes", "gemini", "aider", "goose", "ollama"]) {
                    store.seatForm.harness = $0
                }
            }
            problem("harness")
            FieldBlock(title: "Model") { GlassField(placeholder: "gpt-5.5", text: $store.seatForm.model, monospaced: true) }
            problem("model")
            FieldBlock(title: "Endpoint", detail: "Only for Ollama or another remote model.") {
                GlassField(placeholder: "http://127.0.0.1:11434", text: $store.seatForm.endpoint, monospaced: true)
            }
            problem("endpoint")
            FieldBlock(title: "Version pin", detail: "Optional.") { GlassField(placeholder: "1.2.3", text: $store.seatForm.pin, monospaced: true) }
            problem("pin")
            FieldBlock(title: "Time limit", detail: "Seconds, 1 to 3600. Empty means 120.") { GlassField(placeholder: "120", text: $store.seatForm.cap) }
            problem("capSeconds")
        }
    }

    private var council: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Name") { GlassField(placeholder: "code-review", text: $store.councilForm.name) }
            problem("name")
            FieldBlock(title: "Seats", detail: "Pick the seats that sit together.") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(store.seatNames, id: \.self) { name in
                            SegmentChip(title: name, selected: store.councilForm.seats.contains(name)) { toggle(name) }
                        }
                    }
                }
            }
            problem("seats")
            FieldBlock(title: "Verdict rule") {
                HStack(spacing: Space.s) {
                    ForEach(["majority", "unanimous", "any_blocker"], id: \.self) { rule in
                        SegmentChip(title: rule, selected: store.councilForm.rule == rule) { store.councilForm.rule = rule }
                    }
                }
            }
            problem("rule")
            FieldBlock(title: "Quorum", detail: "Optional. At most the number of seats.") { GlassField(placeholder: "2", text: $store.councilForm.quorum) }
            problem("quorum")
        }
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Who may ask", detail: "Agent names, comma separated, or any.") {
                GlassField(placeholder: "claude, codex", text: $store.routeForm.callers)
            }
            problem("callers")
            FieldBlock(title: "Target") {
                MenuField(title: store.routeForm.target.isEmpty ? "Pick a seat or council" : store.routeForm.target, options: store.targets) {
                    store.routeForm.target = $0
                }
            }
            problem("target")
            FieldBlock(title: "Hop limit", detail: "1 to 4. Empty means 2.") { GlassField(placeholder: "2", text: $store.routeForm.hops) }
            problem("hopLimit")
        }
    }

    private func toggle(_ name: String) {
        if let index = store.councilForm.seats.firstIndex(of: name) { store.councilForm.seats.remove(at: index) }
        else { store.councilForm.seats.append(name) }
    }
}
