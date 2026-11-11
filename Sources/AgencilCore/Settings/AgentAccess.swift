import Foundation

public struct AccessError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) { self.message = message }
}

/// What a harness config holds for Agencil, read back from the file itself.
public struct AccessState: Equatable, Sendable {
    public let harness: String
    public let installed: Bool
    public let path: String?
    public let entry: String?
    public let problem: String?

    public init(harness: String, installed: Bool, path: String?, entry: String?, problem: String?) {
        self.harness = harness
        self.installed = installed
        self.path = path
        self.entry = entry
        self.problem = problem
    }
}

/// The Agent access pane's installs (docs/U9-SPEC.md "AgentAccess"), over the `install-mcp` machinery.
public struct AgentAccess: Sendable {
    /// The harnesses Agencil can wire to ask it, so the only callers a route from Setup can name.
    public static let supported = ["claude", "codex", "opencode"]

    private let installer: McpInstaller
    fileprivate let environment: [String: String]

    public init(home: URL, environment: [String: String]) {
        self.environment = environment
        installer = McpInstaller(home: AgencilHome(existing: home), environment: environment)
    }

    public func state(_ harness: String) throws -> AccessState {
        try require(harness)
        let path = installer.location(harness)
        guard harness != "claude" else {
            // Claude's own CLI writes its config; Agencil's record says the entry is its own, the file shows what it holds.
            let installed = installer.recordsClaude
            let text = installed ? (try? Data(contentsOf: path)).flatMap { String(data: $0, encoding: .utf8) } : nil
            return AccessState(harness: harness, installed: installed, path: path.path,
                               entry: text.flatMap { Self.entry(harness, in: $0) }, problem: nil)
        }
        guard let data = try? Data(contentsOf: path) else {
            return AccessState(harness: harness, installed: false, path: path.path, entry: nil, problem: nil)
        }
        guard let text = String(data: data, encoding: .utf8), installer.parses(harness, text) else {
            return AccessState(harness: harness, installed: false, path: path.path, entry: nil,
                               problem: "\(path.path) does not parse; it was left untouched")
        }
        let installed = installer.declaresAgencil(harness, text)
        return AccessState(harness: harness, installed: installed, path: path.path,
                           entry: installed ? Self.entry(harness, in: text) : nil, problem: nil)
    }

    public func install(_ harness: String) throws -> AccessState { try change(harness, uninstall: false) }

    public func uninstall(_ harness: String) throws -> AccessState { try change(harness, uninstall: true) }

    private func change(_ harness: String, uninstall: Bool) throws -> AccessState {
        try require(harness)
        do { _ = try installer.perform(harness: harness, caller: nil, dryRun: false, uninstall: uninstall) }
        catch let refusal as McpInstaller.Refusal { throw AccessError(message: refusal.message) }
        catch { throw AccessError(message: error.localizedDescription) }
        return try state(harness)
    }

    private func require(_ harness: String) throws {
        guard Self.supported.contains(harness) else { throw AccessError(message: "Agent access supports claude, codex and opencode") }
    }

    /// The entry as the file holds it now: the codex table, or the opencode object as JSON.
    private static func entry(_ harness: String, in text: String) -> String? {
        if harness == "codex" {
            var lines: [Substring] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("[mcp_servers.agencil]") { lines = [line]; continue }
                if lines.isEmpty { continue }
                if line.hasPrefix("[") { break }
                lines.append(line)
            }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let entry = (root[harness == "claude" ? "mcpServers" : "mcp"] as? [String: Any])?["agencil"],
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One harness as the Mac is wired now: the server entry, the instruction paragraph, the routes and what drifted.
public struct Wiring: Equatable, Sendable {
    /// The drift line for an entry whose command is not this app's installed CLI.
    public static let entryMismatch = "server entry does not match this app"
    public static let sandboxBlocks = "sandbox blocks Agencil"
    public static let accessOff = "access is off"
    public static let instructionsOutdated = "instructions outdated"
    public static let instructionsBroken = "instructions markers broken"

    /// The drift lines a state badge already says, which the pane leaves out of its notes.
    public var notes: [String] {
        drift.filter { ![Self.accessOff, Self.instructionsOutdated, Self.instructionsBroken].contains($0) }
    }

    public let harness: String
    public let mcp: AccessState
    public let instruction: InstructionState
    public let caller: String
    public let routes: [String]
    public let drift: [String]

    public init(harness: String, mcp: AccessState, instruction: InstructionState, caller: String, routes: [String], drift: [String]) {
        self.harness = harness
        self.mcp = mcp
        self.instruction = instruction
        self.caller = caller
        self.routes = routes
        self.drift = drift
    }
}

extension AgentAccess {
    /// Reads every file fresh; a harness with nothing installed has no drift. `values` is the config.json snapshot.
    public func audit(values: [String: String]) -> [Wiring] {
        let masterOn = values["agent_access"] == "on"
        let routes = ((try? SeatConfig(values: values))?.routes) ?? []
        return Self.supported.map { harness in
            let mcp = (try? state(harness)) ?? AccessState(harness: harness, installed: false, path: nil, entry: nil, problem: "unreadable")
            let instruction = AgentInstruction(environment: environment).state(harness)
            let targets = routes.filter { $0.callers.contains(harness) }.map(\.target)
            var drift: [String] = []
            if mcp.installed {
                if instruction == .absent { drift.append("instructions missing") }
                if masterOn && targets.isEmpty { drift.append("no route for this caller") }
                if !masterOn { drift.append(Wiring.accessOff) }
                if harness == "claude" && installer.claudeSandboxBlocks { drift.append(Wiring.sandboxBlocks) }
                if let entry = mcp.entry, !Self.runsThisApp(harness, entry) {
                    drift.append(Wiring.entryMismatch)
                }
            } else if instruction != .absent {
                drift.append("instructions without server")
            }
            if instruction == .outdated { drift.append(Wiring.instructionsOutdated) }
            if instruction == .broken { drift.append(Wiring.instructionsBroken) }
            return Wiring(harness: harness, mcp: mcp, instruction: instruction, caller: harness, routes: targets, drift: drift)
        }
    }
}

extension AgentAccess {
    /// Whether the entry's own command (not an argument or comment) is this app's installed CLI.
    fileprivate static func runsThisApp(_ harness: String, _ entry: String) -> Bool {
        let path = "\(NSHomeDirectory())/.local/bin/agencil"
        if harness == "codex" {
            return entry.split(separator: "\n").contains { line in
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && parts[0] == "command" && parts[1] == "\"\(path)\""
            }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(entry.utf8))) as? [String: Any] else { return false }
        // opencode keeps the whole command line in one array; claude keeps a command string and an args array.
        return ((object["command"] as? [String])?.first ?? object["command"] as? String) == path
    }
}
