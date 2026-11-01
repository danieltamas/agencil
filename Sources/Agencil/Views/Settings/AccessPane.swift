import AgencilCore
import SwiftUI

/// Settings > Agent access: the master switch, how an agent reaches this app, what it can call, and how each
/// harness is told about it. Every fact comes from AgencilCore (`AccessFacts`, the audit), never from a copy here.
struct AccessPane: View {
    let store: SettingsStore
    private static let harnesses = ["claude", "codex", "opencode"]

    var body: some View {
        VStack(spacing: Space.xxl) {
            SettingsCard(title: "MCP server", detail: "Off by default.") {
                SwitchRow(title: "Agent access", isOn: Binding(get: { store.agentAccessOn }, set: { store.setAgentAccess($0) }))
                if !store.agentAccessOn {
                    StatusLine(text: "Off: every agent request is refused.", signal: .warn,
                               hint: "Turn it on, then give each caller a route, to let an agent ask.")
                }
            }
            SettingsCard(title: "How agents reach Agencil",
                         detail: "No network port and no HTTP. Each agent starts its own copy of the command below as a stdio MCP server, and that copy talks to this app over a Unix socket.") {
                reach
                RowDivider().padding(.vertical, Space.s)
                tools
            }
            SettingsCard(title: "How agents know", detail: "Two things per agent: an MCP entry that starts the server, and a paragraph in its instruction file that says when to use it. No hooks are involved.") {
                ForEach(Array(Self.harnesses.enumerated()), id: \.element) { index, harness in
                    if index > 0 { RowDivider().padding(.vertical, Space.s) }
                    harnessBlock(harness)
                }
                if let problem = store.accessProblem { ProblemText(text: problem) }
            }
        }
    }

    // MARK: transport

    private var reach: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Eyebrow(text: "Transport")
            line("Command", AccessFacts.command, copy: AccessFacts.command, help: "Copy the command")
            if let socket = store.socket {
                line("Socket", AccessFacts.tilde(socket.path), copy: socket.path, help: "Copy the socket path") {
                    Chip(text: socket.reachable ? "reachable" : "not running", color: Theme.color(for: socket.reachable ? .ok : .warn))
                    Chip(text: socket.ownerOnly ? "owner only" : "open to others", color: Theme.color(for: socket.ownerOnly ? .ok : .crit))
                }
            }
        }
    }

    private func line<Extra: View>(_ title: String, _ value: String, copy: String, help: String,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Space.s)
                extra()
                CopyButton(text: copy, help: help)
            }
            Text(value).font(.house.mono).foregroundStyle(Theme.textSecondary)
                .paragraph().textSelection(.enabled)
        }
    }

    // MARK: tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Eyebrow(text: "Tools (\(AccessFacts.tools.count))")
            ForEach(AccessFacts.tools, id: \.name) { tool in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(tool.name).font(.house.mono).foregroundStyle(Theme.textPrimary)
                    Text(tool.title).font(.house.meta).foregroundStyle(Theme.textSecondary).paragraph()
                    Text(tool.when).font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: per harness

    private func harnessBlock(_ harness: String) -> some View {
        let state = store.access[harness]
        let installed = state?.installed ?? false
        let wiring = store.wiring[harness]
        let instruction = wiring?.instruction ?? .absent
        let present = instruction != .absent
        let routes = wiring?.routes ?? []
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(harness).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Space.s)
                Chip(text: routes.isEmpty ? "no routes" : "\(routes.count) route\(routes.count == 1 ? "" : "s")",
                     color: Theme.color(for: routes.isEmpty ? .warn : .ok))
            }
            if !routes.isEmpty {
                Text(routes.joined(separator: ", ")).font(.house.meta).foregroundStyle(Theme.textTertiary)
                    .paragraph()
            }
            step("MCP entry", detail: state?.path ?? "not found", chip: installed ? "installed" : "absent", signal: installed ? .ok : .unknown) {
                AsyncPress(id: "access:\(harness)", action: store.installAction(harness, uninstall: installed)) { running, press in
                    ChipButton(title: running ? "Working..." : installed ? "Uninstall" : "Install", destructive: installed, action: press)
                }
            }
            if let entry = state?.entry { Text(entry).font(.house.mono).foregroundStyle(Theme.textTertiary).textSelection(.enabled) }
            if let problem = state?.problem { ProblemText(text: problem) }
            step("Instructions", detail: store.instructionPath(harness), chip: instruction.rawValue, signal: Self.signal(instruction)) {
                AsyncPress(id: "instructions:\(harness)", action: store.instructionAction(harness, remove: present)) { running, press in
                    ChipButton(title: running ? "Working..." : present ? "Remove" : "Add", destructive: present, action: press)
                }
            }
            ForEach(wiring?.drift ?? [], id: \.self) { line in ProblemText(text: line) }
        }
    }

    /// A step's name and where it lives on the left; its state and its button on the right, wrapping under at narrow widths.
    private func step<Control: View>(_ title: String, detail: String, chip: String, signal: Signal,
                                    @ViewBuilder control: () -> Control) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.l) {
                stepText(title, detail)
                Spacer(minLength: Space.l)
                Chip(text: chip, color: Theme.color(for: signal))
                control()
            }
            VStack(alignment: .leading, spacing: Space.s) {
                stepText(title, detail)
                HStack(spacing: Space.s) { Chip(text: chip, color: Theme.color(for: signal)); control() }
            }
        }
    }

    private func stepText(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph(ideal: Size.rowText)
        }
    }

    private static func signal(_ state: InstructionState) -> Signal {
        switch state {
        case .current: .ok
        case .outdated: .warn
        case .broken: .crit
        case .absent: .unknown
        }
    }
}
