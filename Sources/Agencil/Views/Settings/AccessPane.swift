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
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("How agents know").font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text("Two things per agent: an MCP entry that starts the server, and a paragraph in its instruction file that says when to use it. No hooks are involved.")
                        .font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph()
                }
                ForEach(Self.harnesses, id: \.self) { harnessCard($0) }
                if let problem = store.accessProblem { ProblemText(text: problem) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private static let vendors = ["claude": "anthropic", "codex": "openai", "opencode": "opencode"]

    /// One agent as one card: its name, mark and route count on top, then the two steps on aligned rows.
    private func harnessCard(_ harness: String) -> some View {
        let state = store.access[harness]
        let wiring = store.wiring[harness]
        let status = AccessFacts.mcpStatus(wiring)
        let instruction = wiring?.instruction ?? .absent
        let present = instruction != .absent
        let routes = wiring?.routes ?? []
        return SettingsCard(title: harness, mark: Self.vendors[harness],
                            accessory: {
            Chip(text: routes.isEmpty ? "no routes" : "\(routes.count) route\(routes.count == 1 ? "" : "s")",
                 color: Theme.color(for: routes.isEmpty ? .warn : .ok))
        }, content: {
            if !routes.isEmpty {
                Text(routes.joined(separator: ", ")).font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph()
            }
            StatusRow(title: "MCP entry", detail: AccessFacts.mcpDetail(state, status: status), status: status.label,
                      color: Theme.color(for: Self.signal(status))) {
                AsyncPress(id: "access:\(harness)", action: store.installAction(harness, uninstall: status.present)) { running, press in
                    ChipButton(title: running ? "Working..." : status.present ? "Uninstall" : "Install",
                               destructive: status.present, width: SettingsMetrics.actionWidth, action: press)
                        .accessibilityLabel("\(status.present ? "Uninstall" : "Install") the \(harness) MCP entry")
                }
            }
            let fields = state?.entry.map(AccessFacts.entryFields) ?? []
            if !fields.isEmpty { EntryLines(fields: fields.map { field in EntryLines.Field(key: field.key, value: field.value) }) }
            if let problem = state?.problem { ProblemText(text: problem) }
            RowDivider()
            StatusRow(title: "Instructions", detail: store.instructionPath(harness), status: AccessFacts.instructionLabel(instruction),
                      color: Theme.color(for: Self.signal(instruction))) {
                AsyncPress(id: "instructions:\(harness)", action: store.instructionAction(harness, remove: present)) { running, press in
                    ChipButton(title: running ? "Working..." : present ? "Remove" : "Add",
                               destructive: present, width: SettingsMetrics.actionWidth, action: press)
                        .accessibilityLabel("\(present ? "Remove" : "Add") the \(harness) instructions")
                }
            }
            ForEach(wiring?.notes ?? [], id: \.self) { line in ProblemText(text: line) }
        })
    }

    private static func signal(_ status: AccessFacts.McpStatus) -> Signal {
        switch status {
        case .installed: .ok
        case .drifted: .warn
        case .notInstalled: .unknown
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
