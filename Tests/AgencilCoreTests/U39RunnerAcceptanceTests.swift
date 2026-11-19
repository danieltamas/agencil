@testable import AgencilCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U39RunnerAcceptanceTests {
    // Acceptance 10: resolve the folder even when the credentials file does not exist yet.
    @Test func linkedFolderDeniesFutureCredentialsByResolvedSpelling() throws {
        let fixture = try BrokerHome()
        let paths = try linkedFolder(fixture.url)
        try #require(!FileManager.default.fileExists(atPath: paths.direct.path))
        let profile = U34Support.profile(fixture.url, harness: "claude")
        let resolved = U34Support.resolved(paths.direct.deletingLastPathComponent()) + "/.credentials.json"
        let escaped = resolved.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let literal = "(literal \"\(escaped)\")"
        let lines = profile.split(separator: "\n")
        let denial = try #require(lines.indices.last {
            lines[$0].hasPrefix("(deny file-read* file-write* ") && lines[$0].contains(literal)
        })
        let grants = lines.indices.filter { lines[$0].contains("(allow file-read*") }
        try #require(!grants.isEmpty)
        #expect(grants.allSatisfy { $0 < denial })
    }

    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func realSandboxDeniesCredentialsCreatedAfterLinkedFolderProfile() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let paths = try linkedFolder(root)
        try #require(!FileManager.default.fileExists(atPath: paths.direct.path))
        let profile = U34Support.profile(root, harness: "claude")
        try U34Support.put(root.appendingPathComponent("profile.sb"), profile)
        // Keep this profile unchanged after creating the file. The helper writes these same bytes.
        try U34Support.put(paths.direct, "fixture-refresh-secret")
        #expect(try String(contentsOf: paths.named, encoding: .utf8) == "fixture-refresh-secret")
        let code = """
        import sys
        for path in sys.argv[1:3]:
            with open(path) as settings:
                assert settings.read() == 'fixture-settings'
        for path in sys.argv[3:]:
            try:
                with open(path) as credentials:
                    credentials.read()
            except PermissionError:
                pass
            else:
                raise AssertionError('late credentials were readable: ' + path)
        print('settings-readable; late-credentials-denied')
        """
        let result = try U34Support.python(root, profile: profile, code: code, arguments: [
            paths.direct.deletingLastPathComponent().appendingPathComponent("settings.json").path,
            paths.named.deletingLastPathComponent().appendingPathComponent("settings.json").path,
            U34Support.resolved(paths.direct), paths.named.path
        ], environment: ["AGENCIL_TEST_SEAMS": "1", "HOME": U34Support.testHome(root)])
        #expect(result.0 == 0, "\(result)")
        #expect(result.1.contains("settings-readable; late-credentials-denied"))
    }

    // Acceptance 11: stdout EOF is not successful process completion.
    @Test func closedStdoutDoesNotBypassSecurityDeadline() throws {
        let fixture = try BrokerHome()
        let stub = try securityStub(fixture.url, beforeOutput: "", afterOutput: """
        exec 1>&-
        exec /bin/sleep 15
        """)
        let start = ContinuousClock.now
        let result = try ClaudeLogin.secretEnvironment(environment: stub.environment, now: U39Support.now)
        let elapsed = start.duration(to: ContinuousClock.now)
        #expect(result == [:])
        #expect(elapsed < .seconds(14), "Security read exceeded the acceptance deadline: \(elapsed)")
        #expect(FileManager.default.fileExists(atPath: stub.marker.path))
    }

    // Acceptance 12: a descendant cannot hold the read open after its parent exits.
    @Test func securityExitKillsBackgroundChildHoldingStdout() throws {
        let fixture = try BrokerHome()
        let pidFile = fixture.url.appendingPathComponent("stdout-child.pid")
        let stub = try securityStub(fixture.url, beforeOutput: """
        /bin/sleep 30 &
        child=$!
        printf '%s' "$child" > \(U39Support.quote(pidFile.path)) || exit 92
        """, afterOutput: "exit 0")
        // Cleanup is after the assertions, including when the runner throws or misses its deadline.
        defer {
            if let pid = childPID(pidFile), brokerAlive(pid) { Darwin.kill(pid, SIGKILL) }
        }
        let start = ContinuousClock.now
        _ = try ClaudeLogin.secretEnvironment(environment: stub.environment, now: U39Support.now)
        let returned = ContinuousClock.now
        #expect(start.duration(to: returned) < .seconds(14), "Security read waited for the background child")
        #expect(FileManager.default.fileExists(atPath: stub.marker.path))
        let pid = try #require(childPID(pidFile), "Stub did not record its background child")
        let deadline = returned + .seconds(5)
        while brokerAlive(pid) && ContinuousClock.now < deadline { usleep(10_000) }
        #expect(!brokerAlive(pid), "Security tool's background child survived five seconds after return")
    }

    private func linkedFolder(_ root: URL) throws -> (named: URL, direct: URL) {
        let home = URL(fileURLWithPath: U34Support.testHome(root))
        // The target is also granted by the repo-copy rule, so only the explicit deny protects it.
        let target = root.appendingPathComponent("run/copy/linked-claude")
        try U34Support.put(target.appendingPathComponent("settings.json"), "fixture-settings")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let link = home.appendingPathComponent(".claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return (link.appendingPathComponent(".credentials.json"), target.appendingPathComponent(".credentials.json"))
    }

    private func securityStub(_ root: URL, beforeOutput: String, afterOutput: String) throws
        -> (environment: [String: String], marker: URL) {
        let home = U34Support.testHome(root)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let item = try U39Support.item(token: "fixture-access", refresh: "fixture-refresh",
                                      expires: U39Support.now.addingTimeInterval(3_600))
        let stub = try U39Support.securityStub(in: root, item: item)
        let script = try String(contentsOf: stub.tool, encoding: .utf8)
        let output = "printf '%s' "
        try #require(script.contains(output) && script.hasSuffix("exit 0"))
        let changed = String(script.dropLast("exit 0".count))
            .replacingOccurrences(of: output, with: beforeOutput + "\n" + output) + afterOutput + "\n"
        try changed.write(to: stub.tool, atomically: false, encoding: .utf8)
        return (["AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_SECURITY": stub.tool.path, "HOME": home], stub.marker)
    }

    private func childPID(_ file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }
}
