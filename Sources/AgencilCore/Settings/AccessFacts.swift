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
        let path = home.socketPath
        var info = stat()
        let ownerOnly = lstat(path, &info) == 0 && info.st_mode & 0o077 == 0
        guard let descriptor = (try? UnixSocket.connect(to: path)) ?? nil else {
            return Socket(path: path, reachable: false, ownerOnly: ownerOnly)
        }
        close(descriptor)
        return Socket(path: path, reachable: true, ownerOnly: ownerOnly)
    }

    public static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
