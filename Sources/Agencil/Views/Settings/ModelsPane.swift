import SwiftUI

/// Settings > Models: the models the seats run on top, then every model Agencil knows with its price, filtered
/// by name or harness. The owner's own models are added and edited here; a seat's Model field offers the same list.
struct ModelsPane: View {
    @Bindable var store: SettingsStore
    @Bindable private var catalog: ModelCatalogStore

    init(store: SettingsStore) {
        self.store = store
        catalog = store.catalog
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            HStack { Spacer(); PillButton(title: "Add model", symbol: "plus") { catalog.startAdd() } }
            inUse
            SettingsCard(title: catalog.title, detail: explainer) {
                age
                controls
                harnessChips
                if let problem = catalog.problem { ProblemText(text: problem) }
                ForEach(catalog.notes, id: \.self) { StatusLine(text: $0, signal: .warn) }
                PriceTable(columns: ModelCatalogStore.columns, rows: catalog.rows, edit: catalog.startEdit)
            }
        }
        .onAppear { catalog.begin() }
        .houseSheet(item: $catalog.presenting, title: { _ in catalog.formTitle },
                    detail: { _ in "Saved to config.json; seats can name it at once." },
                    footer: { _ in
            ModalFooter(secondary: .init(title: "Cancel") { catalog.presenting = nil },
                        primary: .init(title: "Save") { if catalog.save() { catalog.presenting = nil } })
        }) { _ in ModelForm(catalog: catalog) }
    }

    private var explainer: String { "USD per million tokens, from the \(catalog.source) and what your harnesses report. A model without a price shows no price, never a guess." }

    private var age: some View {
        Group {
            if let updated = catalog.updatedAt {
                RelativeTime(date: updated) { "\(catalog.source) - updated \($0) ago" }
            } else {
                Text("Price list not fetched yet")
            }
        }
        .font(.house.meta).foregroundStyle(Theme.textSecondary)
    }

    private var controls: some View {
        HStack(spacing: Space.m) {
            SearchField(text: $catalog.filter, prompt: "Filter")
            AsyncPress(id: "models:refresh", action: catalog.refreshAction()) { running, press in
                PillButton(title: running ? "Refreshing..." : "Refresh", symbol: "arrow.clockwise", prominent: false, disabled: running, action: press)
            }
        }
    }

    private var harnessChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                FilterChip(title: "All", selected: catalog.harnessFilter == nil) { catalog.harnessFilter = nil }
                ForEach(catalog.harnessChoices, id: \.self) { harness in
                    FilterChip(title: harness, selected: catalog.harnessFilter == harness) { catalog.harnessFilter = harness }
                }
            }
        }
    }

    private var inUse: some View {
        let models = store.panes.models
        return SettingsCard(title: "In use", detail: "Models the configured seats run.") {
            if models.isEmpty { SettingsRow(title: "No seats yet", detail: "Add a seat first.") { EmptyView() } }
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { RowDivider() }
                SettingsRow(title: model.id, detail: "Open a seat to edit or delete it.") {
                    HStack(spacing: Space.s) {
                        ForEach(model.seats, id: \.self) { seat in ChipButton(title: seat) { SettingsRoute.shared.show(seat: seat) } }
                    }
                }
            }
        }
    }
}

/// The fields of the Add model and Edit model sheet. Each problem shows under its own field.
struct ModelForm: View {
    @Bindable var catalog: ModelCatalogStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            FieldBlock(title: "Model id", detail: "As the harness names it, for example provider/model.") {
                GlassField(placeholder: "my-model:7b", text: $catalog.form.id, monospaced: true)
            }
            problem("id")
            FieldBlock(title: "Harness", detail: "Which harness runs it.") {
                MenuField(title: catalog.form.harness, options: catalog.harnesses) { catalog.form.harness = $0 }
            }
            problem("harness")
            FieldBlock(title: "Note", detail: "Optional.") { GlassField(placeholder: "fine-tune on the build box", text: $catalog.form.note) }
            problem("note")
            if catalog.formTitle == "Edit model" { deleteBlock }
            problem("form")
        }
    }

    @ViewBuilder private func problem(_ key: String) -> some View {
        if let text = catalog.problems[key] { ProblemText(text: text) }
    }

    private var deleteBlock: some View {
        FieldBlock(title: "Delete", detail: "Removes it from config.json. A seat that names it keeps working.") {
            if catalog.confirmingDelete {
                HStack(spacing: Space.s) {
                    ChipButton(title: "Keep") { catalog.confirmingDelete = false }
                    AsyncPress(id: "delete:model", action: catalog.deleteAction()) { running, press in
                        ChipButton(title: running ? "Deleting..." : "Yes, delete this model", destructive: true, action: press)
                    }
                }
            } else {
                ChipButton(title: "Delete model", destructive: true) { catalog.confirmingDelete = true }
            }
        }
    }
}
