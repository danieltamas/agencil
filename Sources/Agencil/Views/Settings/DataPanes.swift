import AgencilCore
import SwiftUI

/// A field that keeps what is typed and saves it as it changes; the store reports a problem it refuses.
private struct SavedField: View {
    let placeholder: String
    let value: String
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        GlassField(placeholder: placeholder, text: $text)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if new != text { text = new } }
            .onChange(of: text) { _, new in if new != value { save(new) } }
    }
}

/// The panes fed by the broker and the config file (docs/U19-SPEC.md).
extension SettingsPaneView {
    var harnessesPane: some View {
        let panes = store.panes
        return SettingsCard(title: "Found on this Mac", detail: "Seats run on these.") {
            if panes.harnesses.isEmpty { SettingsRow(title: "Nothing read yet", detail: "Press Re-check.") { EmptyView() } }
            ForEach(panes.harnesses) { harness in
                if harness.id != panes.harnesses.first?.id { RowDivider() }
                SettingsRow(title: harness.id, detail: harness.found ? "\(harness.version), \(harness.signedIn == "yes" ? "signed in" : "sign-in \(harness.signedIn)")" : "not installed") {
                    Chip(text: harness.found ? "found" : "missing", color: Theme.color(for: harness.found ? .ok : .crit))
                }
            }
            RowDivider()
            AsyncPress(id: "recheck", action: panes.recheckAction()) { running, press in
                ChipButton(title: running ? "Checking..." : "Re-check", action: press)
            }
        }
    }

    var modelsPane: some View {
        let panes = store.panes
        return SettingsCard(title: "In use", detail: "Models the configured seats run.") {
            if panes.models.isEmpty { SettingsRow(title: "No seats yet", detail: "Add a seat first.") { EmptyView() } }
            ForEach(panes.models) { model in
                if model.id != panes.models.first?.id { RowDivider() }
                SettingsRow(title: model.id, detail: model.seats.joined(separator: ", ")) { EmptyView() }
            }
        }
    }

    var budgetsPane: some View {
        let panes = store.panes
        return VStack(spacing: Space.xxl) {
            SettingsCard(title: "Budgets", detail: "Spend this week against each limit.") {
                if panes.budgets.isEmpty { SettingsRow(title: "No budgets", detail: "Nothing is capped.") { EmptyView() } }
                ForEach(panes.budgets) { budget in
                    if budget.id != panes.budgets.first?.id { RowDivider() }
                    SettingsRow(title: budget.id, detail: budget.detail) {
                        AsyncPress(id: "budget:\(budget.id)", action: panes.removeBudgetAction(budget.id)) { _, press in
                            ChipButton(title: "Remove", destructive: true, action: press)
                        }
                    }
                }
            }
            SettingsCard(title: "New budget", detail: "A weekly dollar cap on one vendor.") {
                SettingsRow(title: "Vendor", detail: "For example the vendor name a seat reports.") {
                    GlassField(placeholder: "vendor", text: $budgetVendor).frame(width: SettingsMetrics.fieldWidth)
                }
                SettingsRow(title: "Dollars per week") {
                    GlassField(placeholder: "50", text: $budgetDollars).frame(width: SettingsMetrics.fieldWidth)
                }
                SwitchRow(title: "Stop at the cap", isOn: $budgetHard)
                AsyncPress(id: "budget:new", action: panes.addBudgetAction(vendor: budgetVendor, dollars: budgetDollars, hard: budgetHard)) { _, press in ChipButton(title: "Add", action: press) }
                if let problem = panes.fieldProblem { ProblemText(text: problem) }
            }
        }
    }

    var scoringPane: some View {
        SettingsCard(title: "How outcomes count", detail: "Fixed by the engine; shown so the numbers can be read.") {
            SettingsRow(title: "Confirmed share", detail: "Confirmed findings over confirmed plus refuted, with a Wilson 95% interval.") { EmptyView() }
            RowDivider()
            SettingsRow(title: "Enough data", detail: "20 decided findings before the learn loop proposes anything.") { EmptyView() }
            RowDivider()
            SettingsRow(title: "Unresolved", detail: "A finding with no event for 30 days stops counting.") { EmptyView() }
            RowDivider()
            SettingsRow(title: "Probation", detail: "A new voting seat needs 50% recall and 60% confirmed share over 10 golden briefs.") { EmptyView() }
        }
    }

    var leaderboardPane: some View {
        let panes = store.panes
        return VStack(spacing: Space.xxl) {
            SettingsCard(title: "Publishing", detail: "Aggregate counts only. See docs/LEADERBOARD.md.") {
                SettingsRow(title: "Repository", detail: "owner/name that holds the leaderboard branch.") {
                    SavedField(placeholder: "owner/name", value: panes.leaderboardRepo) { panes.save("leaderboard_repo", $0) }
                        .frame(width: SettingsMetrics.wideFieldWidth)
                }
                RowDivider()
                SettingsRow(title: "Minimum outcomes", detail: "Cells below this are left out.") {
                    SavedField(placeholder: "20", value: panes.leaderboardMinN) { panes.save("leaderboard_min_n", $0) }
                        .frame(width: SettingsMetrics.fieldWidth)
                }
                RowDivider()
                SwitchRow(title: "Publish daily", detail: panes.leaderboardEnabled ? nil : "Turns on after your first Publish now.",
                          isOn: Binding(get: { panes.leaderboardEnabled }, set: { if !$0 { panes.save("leaderboard_enabled", "0") } }))
                    .disabled(!panes.leaderboardEnabled)
                if let problem = panes.fieldProblem { ProblemText(text: problem) }
            }
            SettingsCard(title: "Now") {
                AsyncPress(id: "lb:preview", action: panes.previewAction()) { running, press in
                    ChipButton(title: running ? "Reading..." : "Preview", action: press)
                }
                RowDivider()
                AsyncPress(id: "lb:publish", action: panes.publishAction()) { running, press in
                    ChipButton(title: running ? "Publishing..." : "Publish now", action: press)
                }
                if let text = panes.previewText { StatusLine(text: text) }
                if let problem = panes.problem { ProblemText(text: problem) }
            }
        }
    }

    var dataPane: some View {
        let panes = store.panes
        return VStack(spacing: Space.xxl) {
            SettingsCard(title: "Raw seat output", detail: "Claims, evidence and verdicts are kept. Only raw output is deleted.") {
                SettingsRow(title: "Keep for", detail: "Days, from 1 to 3650.") {
                    SavedField(placeholder: "90", value: panes.retentionDays) { panes.save("retention_raw_days", $0) }
                        .frame(width: SettingsMetrics.fieldWidth)
                }
                RowDivider()
                SettingsRow(title: "Size", detail: "Ledger \(PaneStore.size(panes.databaseBytes)), raw output \(PaneStore.size(panes.rawBytes)).") {
                    AsyncPress(id: "prune", action: panes.pruneAction()) { running, press in
                        ChipButton(title: running ? "Deleting..." : "Delete old now", destructive: true, action: press)
                    }
                }
                if let problem = panes.fieldProblem ?? panes.problem { ProblemText(text: problem) }
                if let text = panes.previewText { StatusLine(text: text) }
            }
            SettingsCard(title: "Memory export", detail: "Each finished sitting becomes one Markdown file in the repo you turn on.") {
                if panes.targets.isEmpty { SettingsRow(title: "No repos", detail: "Add one below.") { EmptyView() } }
                ForEach(panes.targets) { target in
                    if target.id != panes.targets.first?.id { RowDivider() }
                    SwitchRow(title: target.id, detail: target.folder, isOn: Binding(
                        get: { target.enabled },
                        set: { panes.setTarget(target.id, enabled: $0) }))
                    AsyncPress(id: "mem:\(target.id)", action: panes.removeTargetAction(target.id)) { _, press in
                        ChipButton(title: "Remove", destructive: true, action: press)
                    }
                }
                RowDivider()
                GlassField(placeholder: "/path/to/repo", text: $memoryRepo, monospaced: true)
                GlassField(placeholder: "/path/to/repo/memory", text: $memoryFolder, monospaced: true)
                AsyncPress(id: "mem:new", action: panes.addTargetAction(repo: memoryRepo, folder: memoryFolder)) { _, press in ChipButton(title: "Add", action: press) }
            }
        }
    }

    var appsPane: some View {
        SettingsCard(title: "By the same maker", detail: "Small Mac apps that share this one's shape.") {
            ForEach(Array(Self.apps.enumerated()), id: \.element.name) { index, app in
                if index > 0 { RowDivider() }
                SettingsRow(title: app.name, detail: app.detail) {
                    if let url = URL(string: "https://github.com/\(app.repo)") { Link("Open", destination: url) }
                }
            }
        }
    }

    private static let apps = [
        (name: "MacMax", detail: "Menu bar system monitor.", repo: "danieltamas/macmax"),
        (name: "Bton", detail: "Runs agents on your team's repos.", repo: "danieltamas/bton"),
        (name: "RMJ", detail: "Run my job: builds and tests on the right machine.", repo: "danieltamas/runmyjob"),
    ]
}
