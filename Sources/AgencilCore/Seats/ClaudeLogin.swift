import Foundation

/// A confined Claude seat cannot reach the Keychain that holds the owner's login (docs/U39-SPEC.md). Granting the
/// Keychain would expose every item that trusts `/usr/bin/security`, so the broker reads the one item and hands the
/// seat only its access token; the refresh token never leaves this parse.
enum ClaudeLogin {
    static let variable = "CLAUDE_CODE_OAUTH_TOKEN"
    private static let service = "Claude Code-credentials"
    private static let systemTool = "/usr/bin/security"
    /// A locked Keychain shows a prompt and the tool waits on it; the ask must not.
    private static let readTimeout: Duration = .seconds(10)
    /// A token this close to expiry would die mid-answer.
    private static let expiryMargin = 60.0

    /// The seat's login as secret environment, or nothing when no usable item could be read (the seat then runs logged
    /// out). An expired login stops the ask instead, since the seat could only fail with a misleading reason.
    /// `now` defaults to the moment after the read, since a locked Keychain can hold the read for seconds.
    static func secretEnvironment(environment: [String: String], now: Date? = nil) throws -> [String: String] {
        guard let tool = tool(environment: environment), let item = read(tool: tool),
              let token = try accessToken(item: item, now: now ?? Date()) else { return [:] }
        return [variable: token]
    }

    static func accessToken(item: Data, now: Date) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: item) as? [String: Any],
              let login = object["claudeAiOauth"] as? [String: Any],
              let token = login["accessToken"] as? String, !token.isEmpty else { return nil }
        guard let value = login["expiresAt"] else { return token }
        // A present expiry that is not a plain number cannot be checked, so the item is not used.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        if Date(timeIntervalSince1970: number.doubleValue / 1000) < now.addingTimeInterval(expiryMargin) {
            throw Refusal(exit: 4, message: "failed: the Claude login has expired; use Claude once to refresh it, then ask again")
        }
        return token
    }

    /// Under the test seams only an injected tool is run, so a test never reads the real Keychain.
    private static func tool(environment: [String: String]) -> String? {
        guard environment["AGENCIL_TEST_SEAMS"] == "1" else { return systemTool }
        return environment["AGENCIL_TEST_SECURITY"]
    }

    /// Through the process runner: the tool gets its own process group, the whole group dies at the deadline or when the
    /// tool exits, and a run that passed the deadline is a failure even if it exits 0.
    private static func read(tool: String) -> Data? {
        // Claude files its login under the owner's account name; a stale item of the same service can sit beside it.
        let argv = [tool, "find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        let finished = DispatchSemaphore(value: 0)
        let output = ReadOutput()
        Task.detached { @Sendable in
            output.value = try? await ProcessRunner().run(argv, environment: ["PATH": "/usr/bin:/bin"],
                                                          timeout: readTimeout, gracePeriod: .seconds(1))
            finished.signal()
        }
        finished.wait()
        guard let result = output.value, result.status == 0 else { return nil }
        return result.stdout
    }

    private final class ReadOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProcessOutput?
        var value: ProcessOutput? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
