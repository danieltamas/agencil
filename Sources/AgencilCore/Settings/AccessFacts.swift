import Darwin
import Foundation

/// What the Agent access pane tells the owner about how agents reach Agencil, read from the same constants
/// the server, the installer and the broker use so the pane cannot drift from them.
public enum AccessFacts {
    public struct ToolLine: Equatable, Sendable {
        public let name: String
        public let title: String
        public let when: String
    }

    public struct Socket: Equatable, Sendable {
        public let path: String
        /// A connection to the broker succeeded just now.
        public let reachable: Bool
        /// Mode 0600 or tighter: no group or other bits. False when the socket is not there.
        public let ownerOnly: Bool

        public init(path: String, reachable: Bool, ownerOnly: Bool) {
            self.path = path
            self.reachable = reachable
            self.ownerOnly = ownerOnly
        }
    }

    /// The command every harness's MCP entry runs; `<harness>` is the caller name the broker routes by.
    public static let command = "~/.local/bin/agencil mcp --caller <harness>"

    public static var tools: [ToolLine] { MCPSchemas.tools.map { ToolLine(name: $0.name, title: $0.title, when: $0.when) } }

    /// Where the instruction paragraph lands for a harness, shown with `~` for the home directory.
    public static func instructionPath(_ harness: String, environment: [String: String]) -> String {
        tilde(AgentInstruction(environment: environment).path(harness).path)
    }

    public static func socket(home: AgencilHome) -> Socket {
        // The MCP server, which an agent's access depends on, connects to the agent door.
        let path = home.agentSocketPath
        var info = stat()
        let ownerOnly = lstat(path, &info) == 0 && info.st_mode & 0o077 == 0
        guard let descriptor = (try? UnixSocket.connect(to: path)) ?? nil else {
            return Socket(path: path, reachable: false, ownerOnly: ownerOnly)
        }
        close(descriptor)
        return Socket(path: path, reachable: true, ownerOnly: ownerOnly)
    }

    /// The one fact behind an MCP entry's badge, its detail line and its button.
    public enum McpStatus: Equatable, Sendable {
        case installed, notInstalled, drifted

        public var label: String {
            switch self {
            case .installed: "installed"
            case .notInstalled: "not installed"
            case .drifted: "drifted"
            }
        }

        /// Whether the entry is in the harness config at all (drifted is installed, but pointing elsewhere).
        public var present: Bool { self != .notInstalled }
    }

    public static func mcpStatus(_ wiring: Wiring?) -> McpStatus {
        guard let wiring, wiring.mcp.installed else { return .notInstalled }
        return wiring.drift.contains(Wiring.entryMismatch) ? .drifted : .installed
    }

    /// Where the entry lives, or why there is none: one line in the same voice for every harness.
    public static func mcpDetail(_ state: AccessState?, status: McpStatus) -> String {
        guard let path = state?.path.map(tilde) else { return status.present ? "location unknown" : "no entry yet" }
        if status.present { return path }
        return state?.problem == nil ? "not in \(path)" : "cannot read \(path)"
    }

    /// The instruction paragraph's state in words that match the MCP entry's.
    public static func instructionLabel(_ state: InstructionState) -> String {
        state == .absent ? "not added" : state.rawValue
    }

    /// One labelled line of an MCP entry.
    public struct EntryField: Equatable, Sendable {
        public let key: String
        public let value: String
    }

    /// An entry as readable lines (command, args, caller) from either file format, with `~` for the home directory
    /// and no JSON escaping. An entry that cannot be read gives no lines, never its raw text.
    public static func entryFields(_ entry: String) -> [EntryField] {
        guard let (command, arguments) = entryCommand(entry) else { return [] }
        var args = arguments
        var fields = [EntryField(key: "command", value: tilde(command))]
        var caller: String?
        if let flag = args.firstIndex(of: "--caller"), args.indices.contains(flag + 1) {
            caller = args[flag + 1]
            args.removeSubrange(flag...flag + 1)
        }
        if !args.isEmpty { fields.append(EntryField(key: "args", value: args.joined(separator: " "))) }
        if let caller { fields.append(EntryField(key: "caller", value: caller)) }
        return fields
    }

    private static func entryCommand(_ entry: String) -> (String, [String])? {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
            let args = object["args"] as? [String] ?? []
            if let line = object["command"] as? [String], let first = line.first { return (first, Array(line.dropFirst()) + args) }
            guard let command = object["command"] as? String else { return nil }
            return (command, args)
        }
        var command: String?
        var args: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8), options: .fragmentsAllowed)
            if parts[0] == "command" { command = value as? String }
            if parts[0] == "args" { args = value as? [String] ?? [] }
        }
        return command.map { ($0, args) }
    }

    public static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
