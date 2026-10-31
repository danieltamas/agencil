import Foundation

/// GitHub through the `gh` CLI: its stored sign-in is the only credential, and nothing is sent to any other host.
public struct GhClient: GitHubClient {
    private static let timeout: TimeInterval = 60

    private let repo: String?

    /// `repo` (owner/name) pins workflow dispatch to the configured repository instead of the ambient checkout.
    public init(repo: String? = nil) { self.repo = repo }

    public func get(_ path: String) throws -> GitHubResponse { try call(["api", "--include", path], input: nil) }

    public func put(_ path: String, body: Data) throws -> GitHubResponse {
        try call(["api", "--include", "--method", "PUT", path, "--input", "-"], input: body)
    }

    public func dispatch(workflow: String, ref: String) throws {
        let target = repo.map { ["--repo", $0] } ?? []
        let output = try Self.run(["workflow", "run", workflow, "--ref", ref] + target, input: nil)
        guard output.status == 0 else { throw LeaderboardError(message: "workflow dispatch failed: \(output.error)") }
    }

    private func call(_ arguments: [String], input: Data?) throws -> GitHubResponse {
        let output = try Self.run(arguments, input: input)
        // `--include` prints the status line and headers, a blank line, then the body, also for 4xx answers.
        let text = String(decoding: output.data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n"),
              let status = text.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw LeaderboardError(message: "gh gave no HTTP answer: \(output.error)")
        }
        return GitHubResponse(status: status, body: Data(text[split.upperBound...].utf8))
    }

    private static func run(_ arguments: [String], input: Data?) throws -> (status: Int32, data: Data, error: String) {
        let process = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        do { try process.run() } catch { throw LeaderboardError(message: "cannot run gh: \(error.localizedDescription)") }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, data, error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
