import AgencilCore
import SwiftUI

/// The pane bodies. Scalar rows save through the store as they change; lists and sheets come from the config.
struct SettingsPaneView: View {
    @Bindable var store: SettingsStore
    let pane: SettingsPane
    @State private var look = Appearance.shared.look
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
            case .seats: list(.seat, rows: store.seatRows)
            case .councils: list(.council, rows: store.councilRows)
            case .routes: list(.route, rows: store.routeRows)
            case .access: accessPane
            case .harnesses: harnessesPane
            case .models: modelsPane
            case .budgets: budgetsPane
            case .scoring: scoringPane
            case .leaderboard: leaderboardPane
            case .data: dataPane
            case .apps: MoreAppsPane(store: store)
            case .about: AboutPane(store: store)
            }
        }
        .onAppear { store.panes.begin() }
        .onChange(of: pane) { _, _ in store.panes.begin() }
        .houseSheet(item: $store.presenting, title: { kind in kind.title }, detail: { kind in kind.detail }, footer: { kind in
            ModalFooter(secondary: .init(title: "Cancel") { store.presenting = nil },
                        primary: .init(title: "Create") { if store.save(kind) { store.presenting = nil } })
        }) { kind in NewObjectForm(store: store, kind: kind, problems: store.problems) }
    }

    static func detail(_ pane: SettingsPane) -> String {
        switch pane {
        case .general: "How Agencil looks, starts and tells you things."
        case .seats: "A seat is a harness plus a model. Councils and routes name seats."
        case .councils: "Which seats sit together, how they vote, and what wakes them."
        case .routes: "Who may ask whom, and how far a question may travel."
        case .harnesses: "The coding agents found on this Mac."
        case .models: "Hosted providers and Ollama endpoints."
        case .budgets: "Weekly caps per vendor and council type."
        case .scoring: "How outcomes are counted and when a seat has enough data."
        case .leaderboard: "Publishing the seat leaderboard is off until you turn it on."
        case .data: "Where the ledger lives and what leaves this Mac."
        case .access: "Let your agents ask seats and councils through Agencil."
        case .apps: "Other open source tools from the maker of Agencil, for a Mac that runs coding agents. All MIT, all free."
        case .about: "Who makes it, where it lives, and which build this is."
        }
    }

    private var general: some View {
        VStack(spacing: Space.xxl) {
            SettingsCard(title: "Look", detail: "Applies at once.") {
                HStack(spacing: Space.s) {
                    ForEach(Look.allCases) { item in
                        SegmentChip(title: item.title, selected: look == item) { look = item; Appearance.shared.look = item }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.m)
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
                ForEach(rows) { row in
                    if row.id != rows.first?.id { RowDivider() }
                    SettingsRow(title: row.name, detail: row.detail) {
                        Chip(text: row.up ? "up" : "down", color: Theme.color(for: row.up ? .ok : .crit))
                    }
                }
            }
        }
    }

    private var accessPane: some View {
        VStack(spacing: Space.xxl) {
            SettingsCard(title: "MCP server", detail: "Off by default. Agents are refused while it is off.") {
                SwitchRow(title: "Agent access", isOn: Binding(get: { store.agentAccessOn }, set: { store.setAgentAccess($0) }))
            }
            SettingsCard(title: "Per harness", detail: store.wiringSummary) {
                ForEach(Array(["claude", "codex", "opencode"].enumerated()), id: \.element) { index, harness in
                    if index > 0 { RowDivider() }
                    accessRow(harness)
                }
                if let problem = store.accessProblem { ProblemText(text: problem) }
            }
        }
    }

    private func accessRow(_ harness: String) -> some View {
        let state = store.access[harness]
        let installed = state?.installed ?? false
        return VStack(alignment: .leading, spacing: Space.s) {
            SettingsRow(title: harness, detail: state?.path ?? (installed ? "installed" : "not installed")) {
                AsyncPress(id: "access:\(harness)", action: store.installAction(harness, uninstall: installed)) { running, press in
                    ChipButton(title: running ? "Working..." : installed ? "Uninstall" : "Install for \(harness)", destructive: installed, action: press)
                }
            }
            if let entry = state?.entry { Text(entry).font(.house.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled) }
            if let problem = state?.problem { ProblemText(text: problem) }
            instructionRow(harness)
        }
    }

    private func instructionRow(_ harness: String) -> some View {
        let row = store.wiring[harness]
        let present = (row?.instruction ?? .absent) != .absent
        let routes = (row?.routes ?? []).isEmpty ? "no routes" : "routes: " + (row?.routes ?? []).joined(separator: ", ")
        return VStack(alignment: .leading, spacing: Space.s) {
            SettingsRow(title: "Instructions", detail: "\(row?.instruction.rawValue ?? "absent"), \(routes)") {
                AsyncPress(id: "instructions:\(harness)", action: store.instructionAction(harness, remove: present)) { running, press in
                    ChipButton(title: running ? "Working..." : present ? "Remove" : "Add", destructive: present, action: press)
                }
            }
            ForEach(row?.drift ?? [], id: \.self) { line in ProblemText(text: line) }
        }
    }
}
