@testable import AgencilCore
import Foundation
import Testing

@Suite(.serialized)
struct U39HardeningAcceptanceTests {
    // Acceptance 6: a present, invalid expiry is not the same as an absent expiry.
    @Test(arguments: ["null", "\"1794721718236\"", "true"])
    func invalidExpiryReturnsNil(expiry: String) throws {
        let item = """
        {"claudeAiOauth":{"accessToken":"fixture-access","expiresAt":\(expiry)}}
        """
        #expect(try ClaudeLogin.accessToken(item: Data(item.utf8), now: U39Support.now) == nil)
    }

    // Acceptance 7: usable bytes received before the deadline cannot rescue a late exit.
    @Test func securityReadPastDeadlineDiscardsItemAndReturnsPromptly() throws {
        let fixture = try BrokerHome()
        let home = U34Support.testHome(fixture.url)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let item = try U39Support.item(token: "fixture-access", refresh: "fixture-refresh",
                                      expires: U39Support.now.addingTimeInterval(3_600))
        let stub = try U39Support.securityStub(in: fixture.url, item: item)
        let script = try String(contentsOf: stub.tool, encoding: .utf8)
        try #require(script.hasSuffix("exit 0"))
        // exec keeps the sleeper in the tool's PID, so deadline cleanup has no orphan child.
        try (String(script.dropLast("exit 0".count)) + "exec /bin/sleep 15\n")
            .write(to: stub.tool, atomically: false, encoding: .utf8)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try ClaudeLogin.secretEnvironment(environment: [
            "AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_SECURITY": stub.tool.path, "HOME": home
        ], now: U39Support.now)
        let elapsed = start.duration(to: clock.now)
        #expect(result == [:])
        #expect(elapsed < .seconds(14), "Security read exceeded the acceptance deadline: \(elapsed)")
        #expect(FileManager.default.fileExists(atPath: stub.marker.path))
    }

    // Acceptance 8: both spellings must be denied after all read grants, for Claude only.
    @Test(arguments: [false, true])
    func claudeProfileEndsWithCredentialDenial(linked: Bool) throws {
        let fixture = try BrokerHome(), root = fixture.url
        let credentials = try credentialFile(root, linked: linked)
        let paths = Set([credentials.path, U34Support.resolved(credentials)])
        if linked {
            #expect(U34Support.resolved(credentials) ==
                    U34Support.resolved(root.appendingPathComponent("run/copy/linked-login.json")))
            #expect(U34Support.resolved(credentials) != credentials.path)
        }
        let lines = U34Support.profile(root, harness: "claude")
            .split(separator: "\n").map(String.init)
        let grants = lines.indices.filter { lines[$0].contains("(allow file-read*") }
        try #require(!grants.isEmpty)
        for path in paths {
            let literal = sandboxLiteral(path)
            let deny = try #require(lines.indices.last { index in
                lines[index].hasPrefix("(deny file-read* file-write* ") && lines[index].contains(literal)
            })
            #expect(grants.allSatisfy { $0 < deny })
            #expect(deny == lines.count - 1)
            let codexLines = U34Support.profile(root, harness: "codex").split(separator: "\n")
            #expect(!codexLines.contains { $0.contains("(deny file-read*") && $0.contains(literal) })
        }
    }

    // Acceptance 9: denial must not come from a missing file or a blanket config denial.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"),
          arguments: [false, true])
    func realSandboxHidesCredentialsAndReadsSettings(linked: Bool) throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = U34Support.testHome(root)
        let credentials = try credentialFile(root, linked: linked)
        let settings = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        let settingsText = "{\"fixture\":\"settings-readable\"}"
        try U34Support.put(settings, settingsText)
        #expect(try String(contentsOf: credentials, encoding: .utf8) == "fixture-refresh-secret")
        let code = """
        import sys
        with open(sys.argv[1]) as settings:
            assert settings.read() == sys.argv[2]
        for path in sys.argv[3:]:
            try:
                with open(path) as credentials:
                    credentials.read()
            except PermissionError:
                pass
            else:
                raise AssertionError('credential file was readable')
        print('settings-readable; credentials-denied')
        """
        let result = try U34Support.python(root, profile: U34Support.profile(root, harness: "claude"),
            code: code, arguments: [settings.path, settingsText, credentials.path, U34Support.resolved(credentials)],
            environment: ["AGENCIL_TEST_SEAMS": "1", "HOME": home])
        #expect(result.0 == 0, "\(result)")
        #expect(result.1.contains("settings-readable; credentials-denied"))
    }

    private func credentialFile(_ root: URL, linked: Bool) throws -> URL {
        let home = URL(fileURLWithPath: U34Support.testHome(root))
        let credentials = home.appendingPathComponent(".claude/.credentials.json")
        if linked {
            // The target is otherwise readable through the repo-copy grant.
            let target = root.appendingPathComponent("run/copy/linked-login.json")
            try U34Support.put(target, "fixture-refresh-secret")
            try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: credentials, withDestinationURL: target)
        } else {
            try U34Support.put(credentials, "fixture-refresh-secret")
        }
        return credentials
    }

    private func sandboxLiteral(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "(literal \"\(escaped)\")"
    }
}
