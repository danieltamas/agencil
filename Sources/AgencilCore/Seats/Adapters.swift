import Foundation

/// What an adapter promises about the process it builds. A route or council that needs a policy the adapter
/// does not enforce is refused (U6d consumes this).
public enum Policy: String, Sendable { case readOnlyFiles, noNetworkTools, noFurtherMCP }

/// The process an adapter builds for one seat run: argv (the prompt is one argument, never a shell string),
/// environment additions, and where the answer comes from.
public struct Invocation: Equatable, Sendable {
    public let argv: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    /// True when the answer is the process's stdout; false when it is the file the adapter named in argv.
    public let stdoutIsAnswer: Bool
}

/// Harness adapters: the hardened argv for each kind, as pure functions of the seat and the run.
public enum Adapter {
    public static func enforces(_ harness: String) -> Set<Policy> {
        switch harness {
        case "codex", "claude": [.readOnlyFiles, .noNetworkTools, .noFurtherMCP]
        case "opencode": [.readOnlyFiles, .noNetworkTools]
        default: []
        }
    }

    /// Nil for harnesses with no process adapter (ollama is a request; the rest are not adapted in 0.1.0).
    public static func command(seat: Seat, executable: String, prompt: String, answerFile: String,
                               runDirectory: String) throws -> Invocation? {
        switch seat.harness {
        case "codex":
            return Invocation(argv: [executable, "exec", "--ignore-user-config", "--disable", "hooks", "-s", "read-only",
                                     "--skip-git-repo-check", "-o", answerFile, "-m", seat.model, prompt],
                              environment: [:], workingDirectory: nil, stdoutIsAnswer: false)
        case "claude":
            return Invocation(argv: [executable, "-p", prompt, "--model", seat.model, "--setting-sources", "user",
                                     "--strict-mcp-config", "--permission-mode", "plan"],
                              environment: [:], workingDirectory: nil, stdoutIsAnswer: true)
        case "opencode":
            // OpenCode's external-directory rule is a permission prompt, not OS isolation: the run's own config
            // denies edit, bash, web fetch and external directories, and the run starts inside its directory.
            let config = runDirectory + "/opencode.json"
            let policy = ["permission": ["edit": "deny", "bash": "deny", "webfetch": "deny", "external_directory": "deny"]]
            try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(to: URL(fileURLWithPath: config))
            return Invocation(argv: [executable, "run", "--model", seat.model, prompt],
                              environment: ["OPENCODE_CONFIG": config], workingDirectory: runDirectory, stdoutIsAnswer: true)
        case "hermes":
            return Invocation(argv: [executable, "chat", "-q", prompt, "--model", seat.model],
                              environment: [:], workingDirectory: nil, stdoutIsAnswer: true)
        default:
            return nil
        }
    }

    /// The labelled evidence a seat is shown: the question, the files, never instructions from them.
    public static func prompt(question: String, files: [(path: String, text: String)], transcript: [(asked: String, answered: String)]) -> String {
        var parts: [String] = []
        for exchange in transcript { parts.append("ASKED:\n\(exchange.asked)\nANSWERED:\n\(exchange.answered)") }
        parts.append("QUESTION:\n\(question)")
        for file in files { parts.append("FILE \(file.path):\n\(file.text)") }
        return parts.joined(separator: "\n\n")
    }
}
