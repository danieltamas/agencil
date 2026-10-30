import AgencilCore
import SwiftUI

/// The pane bodies on demo data. Scalar rows save as they change once the store is wired (U9).
struct SettingsPaneView: View {
    let pane: SettingsPane
    @State private var look = Appearance.shared.look
    @State private var login = true
    @State private var verdicts = true
    @State private var blocks = true
    @State private var access = true
    @State private var publish = false
    @State private var sheet: NewObject?
    @State private var atOnce = "3"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PaneHeader(symbol: pane.symbol, eyebrow: pane.title, color: pane.tint.color, title: pane.title, detail: Self.detail(pane))
            switch pane {
            case .general: general
            case .seats: list("New seat", rows: DemoPanel.seatRows.map { seat in DemoPanel.ListRow(name: seat.id, detail: seat.model, up: seat.up) })
            case .councils: list("New council", rows: DemoPanel.councils)
            case .routes: list("New route", rows: DemoPanel.routes)
            case .harnesses: harnesses
            case .access: accessPane
            case .leaderboard: leaderboard
            case .about: about
            default: placeholder
            }
        }
        .houseSheet(item: $sheet, title: { object in object.title }, detail: { object in object.detail }, footer: { _ in
            ModalFooter(secondary: .init(title: "Cancel") { sheet = nil }, primary: .init(title: "Create") { sheet = nil })
        }) { object in NewObjectForm(object: object) }
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
        case .apps: "Other apps by the same maker."
        case .about: "Agencil convenes councils of coding agents."
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
                SwitchRow(title: "Open at login", isOn: $login)
                RowDivider()
                SettingsRow(title: "Seats at once", detail: "Councils wait when this many are thinking.") {
                    GlassField(placeholder: "3", text: $atOnce).frame(width: SettingsMetrics.fieldWidth)
                }
            }
            SettingsCard(title: "Notifications", detail: "Never on the first read after launch.") {
                SwitchRow(title: "Verdicts", isOn: $verdicts)
                RowDivider()
                SwitchRow(title: "BLOCK verdicts", isOn: $blocks)
            }
        }
    }

    private func list(_ newTitle: String, rows: [DemoPanel.ListRow]) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack { Spacer(); PillButton(title: newTitle, symbol: "plus") { sheet = NewObject(kind: newTitle) } }
            SettingsCard(title: "Configured") {
                ForEach(rows) { row in
                    if row.id != rows.first?.id { RowDivider() }
                    SettingsRow(title: row.name, detail: row.detail) {
                        Chip(text: row.up ? "up" : "down", color: Theme.color(for: row.up ? .ok : .crit))
                    }
                }
            }
        }
    }

    private var harnesses: some View {
        SettingsCard(title: "Detected") {
            ForEach(DemoPanel.harnesses) { row in
                if row.id != DemoPanel.harnesses.first?.id { RowDivider() }
                SettingsRow(title: row.name, detail: row.detail) {
                    Chip(text: row.up ? "signed in" : "missing", color: Theme.color(for: row.up ? .ok : .unknown))
                }
            }
        }
    }

    private var accessPane: some View {
        VStack(spacing: Space.xxl) {
            SettingsCard(title: "MCP server", detail: "Off by default. Agents are refused while it is off.") {
                SwitchRow(title: "Agent access", isOn: $access)
            }
            SettingsCard(title: "Per harness") {
                SettingsRow(title: "codex", detail: "~/.codex/config.toml") { ChipButton(title: "Uninstall") {} }
                RowDivider()
                SettingsRow(title: "claude", detail: "not installed") { ChipButton(title: "Install for claude") {} }
                RowDivider()
                SettingsRow(title: "opencode", detail: "~/.config/opencode/opencode.json") { ChipButton(title: "Install for opencode") {} }
            }
        }
    }

    private var leaderboard: some View {
        SettingsCard(title: "Publishing", detail: "Shows only seat names, counts and intervals.") {
            SwitchRow(title: "Publish the leaderboard", isOn: $publish)
        }
    }

    private var about: some View {
        SettingsCard(title: "Agencil") {
            SettingsRow(title: "Version", detail: "Built from source") { Chip(text: AgencilVersion.current(), color: Theme.unknown) }
        }
    }

    private var placeholder: some View {
        EmptyState(symbol: pane.symbol, title: "\(pane.title) lands with its unit", detail: "This pane is laid out in the design standard.")
    }
}
