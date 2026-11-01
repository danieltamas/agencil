import AgencilCore
import SwiftUI

/// The fields of the "New ..." and "Edit ..." sheets. Each problem the store reports shows under its own field;
/// one the store cannot place shows at the foot under `form`.
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
            if store.editing != nil { deleteBlock }
            problem("form")
        }
    }

    @ViewBuilder private func problem(_ key: String) -> some View {
        if let text = problems[key] { ProblemText(text: text) }
    }

    /// Delete asks once inside the sheet; a refusal shows under it through `form`.
    private var deleteBlock: some View {
        FieldBlock(title: "Delete", detail: "Removes it from config.json. Refused while something still uses it.") {
            if store.confirmingDelete {
                HStack(spacing: Space.s) {
                    ChipButton(title: "Keep") { store.confirmingDelete = false }
                    AsyncPress(id: "delete:\(kind.rawValue)", action: store.deleteAction(kind)) { running, press in
                        ChipButton(title: running ? "Deleting..." : "Yes, delete this \(kind.rawValue)", destructive: true, action: press)
                    }
                }
            } else {
                ChipButton(title: "Delete \(kind.rawValue)", destructive: true) { store.confirmingDelete = true }
            }
        }
    }

    private var seat: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if store.editing == nil {
                FieldBlock(title: "Preset", detail: "Fills the fields below; edit any of them before saving.") {
                    MenuField(title: store.seatForm.preset.isEmpty ? "Pick a preset" : store.seatForm.preset, options: SeatPreset.all.map(\.name)) {
                        store.applyPreset($0)
                    }
                }
            }
            FieldBlock(title: "Name") { GlassField(placeholder: "reviewer-one", text: $store.seatForm.name) }
            problem("name")
            FieldBlock(title: "Harness") {
                MenuField(title: store.seatForm.harness, options: ["claude", "codex", "opencode", "hermes", "gemini", "aider", "goose", "ollama"]) {
                    store.seatForm.harness = $0
                }
            }
            problem("harness")
            FieldBlock(title: "Model", detail: "Pick one this harness knows, or type any id.") {
                SuggestField(placeholder: "gpt-5.5", text: $store.seatForm.model, options: store.catalog.ids(for: store.seatForm.harness))
            }
            problem("model")
            FieldBlock(title: "Endpoint", detail: "Only for Ollama or another remote model.") {
                GlassField(placeholder: "http://127.0.0.1:11434", text: $store.seatForm.endpoint, monospaced: true)
            }
            problem("endpoint")
            FieldBlock(title: "Version pin", detail: "Optional.") { GlassField(placeholder: "1.2.3", text: $store.seatForm.pin, monospaced: true) }
            problem("pin")
            FieldBlock(title: "Time limit", detail: "Seconds, 1 to 3600. Empty means 120.") { GlassField(placeholder: "120", text: $store.seatForm.cap) }
            problem("capSeconds")
            seatDetails
        }
    }

    /// The fields a preset fills; left empty, the config infers them from the harness and model.
    private var seatDetails: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Role", detail: "What the seat does in a sitting. Empty means answerer.") {
                MenuField(title: store.seatForm.role.isEmpty ? "answerer" : store.seatForm.role, options: ["answerer", "finder", "skeptic", "synthesizer"]) {
                    store.seatForm.role = $0
                }
            }
            problem("role")
            FieldBlock(title: "Plan", detail: "How the seat is paid for. Inferred from the harness and model unless set.") {
                MenuField(title: store.seatForm.plan.isEmpty ? "inferred" : store.seatForm.plan, options: ["inferred", "subscription", "credit", "free", "local"]) {
                    store.seatForm.plan = $0 == "inferred" ? "" : $0
                }
            }
            problem("plan")
            FieldBlock(title: "Vendor", detail: "Who makes the model, for the budgets. Inferred from the harness unless set.") {
                GlassField(placeholder: "anthropic", text: $store.seatForm.vendor, monospaced: true)
            }
            problem("vendor")
            FieldBlock(title: "Hosted", detail: "Whether prompts leave this Mac. Inferred from the harness and endpoint unless set.") {
                MenuField(title: store.seatForm.hosted.map { $0 ? "hosted" : "local" } ?? "inferred", options: ["inferred", "hosted", "local"]) {
                    store.seatForm.hosted = $0 == "inferred" ? nil : $0 == "hosted"
                }
            }
            problem("hosted")
        }
    }

    private var council: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Name") { GlassField(placeholder: "code-review", text: $store.councilForm.name) }
            problem("name")
            FieldBlock(title: "Seats", detail: "Pick the seats that sit together.") { seatChips(store.seatNames, picked: store.councilForm.seats, toggle: toggleSeat) }
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
            FieldBlock(title: "Spare seats", detail: "Optional. Called in when a seat cannot sit. Not also a seat of this council.") {
                seatChips(store.seatNames.filter { !store.councilForm.seats.contains($0) }, picked: store.councilForm.spare, toggle: toggleSpare)
            }
            problem("spare")
            FieldBlock(title: "Synthesizers", detail: "Optional. Write the closing summary. Not also a seat or spare of this council.") {
                seatChips(store.seatNames.filter { !store.councilForm.seats.contains($0) && !store.councilForm.spare.contains($0) },
                          picked: store.councilForm.synthesizer, toggle: toggleSynthesizer)
            }
            problem("synthesizer")
        }
    }

    @ViewBuilder private func seatChips(_ names: [String], picked: [String], toggle: @escaping (String) -> Void) -> some View {
        if names.isEmpty {
            Text("No other seats to pick.").font(.house.meta).foregroundStyle(Theme.textTertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(names, id: \.self) { name in
                        SegmentChip(title: name, selected: picked.contains(name)) { toggle(name) }
                    }
                }
            }
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

    /// A seat that joins the council leaves the spares and synthesizers, which may not hold a seat of it.
    private func toggleSeat(_ name: String) {
        if let index = store.councilForm.seats.firstIndex(of: name) { store.councilForm.seats.remove(at: index) }
        else {
            store.councilForm.seats.append(name)
            store.councilForm.spare.removeAll { $0 == name }
            store.councilForm.synthesizer.removeAll { $0 == name }
        }
    }

    private func toggleSpare(_ name: String) {
        if let index = store.councilForm.spare.firstIndex(of: name) { store.councilForm.spare.remove(at: index) }
        else {
            store.councilForm.spare.append(name)
            store.councilForm.synthesizer.removeAll { $0 == name }
        }
    }

    private func toggleSynthesizer(_ name: String) {
        if let index = store.councilForm.synthesizer.firstIndex(of: name) { store.councilForm.synthesizer.remove(at: index) }
        else { store.councilForm.synthesizer.append(name) }
    }
}
