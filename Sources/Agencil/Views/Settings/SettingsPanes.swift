import AgencilCore
import SwiftUI

/// The pane bodies. Scalar rows save through the store as they change; lists and sheets come from the config.
struct SettingsPaneView: View {
    @Bindable var store: SettingsStore
    let pane: SettingsPane
    @State private var look = Appearance.shared.look
    @State private var lookProblem: String?
    @State var budgetVendor = ""
    @State var budgetDollars = ""
    @State var budgetHard = false
    @State var memoryRepo = ""
    @State var memoryFolder = ""

    init(store: SettingsStore, pane: SettingsPane) {
        self.store = store
        self.pane = pane
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PaneHeader(symbol: pane.symbol, eyebrow: pane.title, color: pane.tint.color,
                       title: pane == .about ? "About Agencil" : pane.title, detail: Self.detail(pane))
            if let problem = store.configProblem { ProblemText(text: problem) }
            switch pane {
            case .general: general
            case .seats: SeatsPane(store: store)
            case .councils: list(.council, rows: store.councilRows)
            case .routes: list(.route, rows: store.routeRows)
            case .access: AccessPane(store: store)
            case .harnesses: harnessesPane
            case .models: ModelsPane(store: store)
            case .budgets: budgetsPane
            case .costs: CostsPane(store: store.costs, open: { SettingsRoute.shared.show(detail: $0) })
            case .scoring: scoringPane
            case .leaderboard: leaderboardPane
            case .data: dataPane
            case .apps: MoreAppsPane(store: store)
            case .about: AboutPane(store: store)
            }
        }
        .onAppear { store.panes.begin(); if pane == .costs { store.loadCosts() } }
        .onChange(of: pane) { _, now in if now == .costs { store.loadCosts() } else { store.stopCosts() } }
        .onDisappear { store.stopCosts() }
        .onChange(of: pane) { _, _ in store.panes.begin() }
        .houseSheet(item: $store.presenting, title: { kind in store.sheetTitle(kind) }, detail: { kind in kind.detail }, footer: { kind in
            ModalFooter(secondary: .init(title: "Cancel") { store.presenting = nil },
                        primary: .init(title: store.sheetPrimaryTitle()) { if store.save(kind) { store.presenting = nil } })
        }) { kind in NewObjectForm(store: store, kind: kind, problems: store.problems) }
    }

    static func detail(_ pane: SettingsPane) -> String {
        switch pane {
        case .general: "How Agencil looks, starts and tells you things."
        case .seats: "A seat is a harness plus a model. Councils and routes name seats."
        case .councils: "Which seats sit together, how they vote, and what wakes them."
        case .routes: "Who may ask whom, and how far a question may travel."
        case .harnesses: "The coding agents found on this Mac."
        case .models: "Every model your harnesses and the public price list know, and any you add yourself."
        case .budgets: "Weekly caps per vendor and council type."
        case .costs: "What every seat call on this Mac has cost, read from the ledger."
        case .scoring: "How outcomes are counted and when a seat has enough data."
        case .leaderboard: "Publishing the seat leaderboard is off until you turn it on."
        case .data: "Where the ledger lives and what leaves this Mac."
        case .access: "Let your agents ask seats and councils through Agencil."
        case .apps: "Other open source tools from the maker of Agencil, for a Mac that runs coding agents. All MIT, all free."
        case .about: "Who makes it, where it lives, and which build this is."
        }
    }

    /// The look is kept in config.json: a choice that cannot be saved is not applied, and says why.
    private func choose(_ item: Look) {
        do {
            try Appearance.shared.choose(item)
            look = item
            lookProblem = nil
        } catch {
            lookProblem = "The look could not be saved: \(error.localizedDescription)"
        }
    }

    private var general: some View {
        VStack(spacing: Space.xxl) {
            SettingsCard(title: "Look", detail: "Applies at once.") {
                HStack(spacing: Space.s) {
                    ForEach(Look.allCases) { item in
                        SegmentChip(title: item.title, selected: look == item) { choose(item) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.m)
                if let lookProblem { ProblemText(text: lookProblem) }
            }
            SettingsCard(title: "Running") {
                SwitchRow(title: "Open at login", isOn: Binding(get: { store.openAtLogin }, set: { store.setOpenAtLogin($0) }))
                RowDivider()
                SettingsRow(title: "Seats at once", detail: "Councils wait when this many are thinking.") {
                    GlassField(placeholder: "3", text: Binding(get: { store.seatsAtOnce }, set: { store.setSeatsAtOnce($0) }))
                        .frame(width: SettingsMetrics.fieldWidth)
                }
                if let problem = store.limitsProblem { ProblemText(text: problem) }
            }
            SettingsCard(title: "Notifications", detail: "Never on the first read after launch.") {
                ForEach(Array(NotifySettings.kinds.sorted().enumerated()), id: \.element) { index, kind in
                    if index > 0 { RowDivider() }
                    SwitchRow(title: kind.capitalized, isOn: Binding(get: { store.notifies(kind) }, set: { store.setNotify(kind, $0) }))
                }
            }
        }
    }

    private func list(_ kind: SheetKind, rows: [DemoPanel.ListRow]) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack { Spacer(); PillButton(title: kind.title, symbol: "plus") { store.startSheet(kind); store.presenting = kind } }
            SettingsCard(title: "Configured") {
                if rows.isEmpty {
                    SettingsRow(title: "Nothing yet", detail: "Create the first one with the button above.") { EmptyView() }
                }
                // Offsets, not names: two routes can read the same.
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    PressRow(label: "Edit \(row.name)") { store.startEdit(kind, index: index) } content: {
                        SettingsRow(title: row.name, detail: row.detail) {
                            HStack(spacing: Space.m) {
                                Chip(text: row.up ? "up" : "down", color: Theme.color(for: row.up ? .ok : .crit))
                                Image(systemName: "chevron.right").font(.house.meta).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}
