@testable import AgencilCore
import Foundation
import Testing

@Suite(.serialized)
struct U39ClaudeLoginAcceptanceTests {
    // Acceptance 1: deterministic milliseconds, without any process or Keychain read.
    @Test(arguments: [true, false])
    func usableItemReturnsOnlyAccessToken(withExpiry: Bool) throws {
        let token = "u39-token-" + UUID().uuidString
        let data = try U39Support.item(token: token, refresh: "u39-refresh-" + UUID().uuidString,
                                      expires: withExpiry ? U39Support.now.addingTimeInterval(3_600) : nil)
        #expect(try ClaudeLogin.accessToken(item: data, now: U39Support.now) == token)
    }

    @Test(arguments: ["not JSON", "{}", "{\"claudeAiOauth\":{\"accessToken\":\"\"}}"])
    func unusableItemsReturnNil(item: String) throws {
        #expect(try ClaudeLogin.accessToken(item: Data(item.utf8), now: U39Support.now) == nil)
    }

    @Test(arguments: [-3_600.0, 30.0])
    func expiredAndNearlyExpiredItemsRefuse(secondsAhead: Double) throws {
        let item = try U39Support.item(token: "u39-token-" + UUID().uuidString,
                                      refresh: "u39-refresh-" + UUID().uuidString,
                                      expires: U39Support.now.addingTimeInterval(secondsAhead))
        do {
            _ = try ClaudeLogin.accessToken(item: item, now: U39Support.now)
            Issue.record("Expected an expired-login Refusal")
        } catch let refusal as Refusal {
            #expect(refusal.message.contains("expired"))
        }
    }

    // Interface contract: the seam is explicit in every call; none can read the real Keychain.
    @Test func securitySeamReturnsOnlyTheAccessToken() throws {
        let home = try BrokerHome()
        let token = "u39-token-" + UUID().uuidString
        let refresh = "u39-refresh-" + UUID().uuidString
        let item = try U39Support.item(token: token, refresh: refresh,
                                      expires: U39Support.now.addingTimeInterval(3_600))
        let stub = try U39Support.securityStub(in: home.url, item: item)
        let result = try ClaudeLogin.secretEnvironment(
            environment: ["AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_SECURITY": stub.tool.path], now: U39Support.now)
        #expect(result == ["CLAUDE_CODE_OAUTH_TOKEN": token])
        #expect(FileManager.default.fileExists(atPath: stub.marker.path))
    }

    @Test func seamWithoutExecutableReadsNothing() throws {
        #expect(try ClaudeLogin.secretEnvironment(environment: ["AGENCIL_TEST_SEAMS": "1"],
                                                   now: U39Support.now).isEmpty)
    }

    @Test(arguments: ["failure", "invalid", "empty"])
    func unavailableSecurityItemHasNoSecretEnvironment(scenario: String) throws {
        let home = try BrokerHome()
        let item = scenario == "failure"
            ? try U39Support.item(token: "u39-token-" + UUID().uuidString, refresh: "refresh", expires: nil)
            : Data((scenario == "invalid" ? "not JSON" : "").utf8)
        let stub = try U39Support.securityStub(in: home.url, item: item, exit: scenario == "failure" ? 1 : 0)
        #expect(try ClaudeLogin.secretEnvironment(
            environment: ["AGENCIL_TEST_SEAMS": "1", "AGENCIL_TEST_SECURITY": stub.tool.path],
            now: U39Support.now).isEmpty)
        #expect(FileManager.default.fileExists(atPath: stub.marker.path))
    }

    // Acceptance 2: a real confined ask, observed inside the harness, then byte-scan persistence.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func confinedClaudeReceivesTokenAndRunTemporaryDirectoryWithoutPersistingSecrets() throws {
        let fixture = try U39Rig()
        _ = try fixture.rig.base.answered(fixture.ask())
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(try fixture.observation(".u39-token-present") == "set")
        #expect(try fixture.observation(".u39-token") == fixture.token)
        let cwd = try fixture.observation(".cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        let run = URL(fileURLWithPath: cwd).deletingLastPathComponent()
        #expect(U34Support.resolved(run).hasPrefix(
            U34Support.resolved(fixture.rig.home.url.appendingPathComponent("runs")) + "/"))
        for suffix in [".u39-tmpdir", ".u39-system-tmpdir"] {
            let observed = try fixture.observation(suffix)
            #expect(U34Support.resolved(URL(fileURLWithPath: observed)) ==
                    U34Support.resolved(run.appendingPathComponent("tmp")))
        }
        #expect(try !fixture.observation(".u39-environment").contains(fixture.refresh))
        try fixture.rig.removedCopy()
        try fixture.assertNoPersistedCredentials()
    }

    // Acceptance 3.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func confinedClaudeWithoutSecuritySeamLaunchesWithoutToken() throws {
        let fixture = try U39Rig(security: false)
        _ = try fixture.rig.base.answered(fixture.ask())
        try fixture.assertLaunchedWithoutToken()
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    // Acceptance 4: a successful security read of an expired item must stop the answer invocation.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func expiredClaudeLoginFailsBeforeHarnessLaunch() throws {
        let fixture = try U39Rig(expired: true)
        let reply = try fixture.ask()
        #expect(reply["ok"] as? Bool == false)
        let reason = try #require(reply["error"] as? String)
        #expect(reason.contains("expired"))
        #expect(!reason.contains(fixture.token))
        #expect(!reason.contains(fixture.refresh))
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        try fixture.assertNeverLaunched()
        try fixture.assertNoPersistedCredentials()
    }

    // Acceptance 5: each scenario has a fresh marker and distinctive credentials.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func confinedCodexDoesNotReadOrReceiveClaudeLogin() throws {
        let fixture = try U39Rig(harness: "codex")
        _ = try fixture.rig.base.answered(fixture.ask())
        try fixture.assertLaunchedWithoutToken()
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        try fixture.assertNoPersistedCredentials()
    }

    @Test func unconfinedClaudeDoesNotReadOrReceiveBrokerLogin() throws {
        let fixture = try U39Rig(confined: false)
        _ = try fixture.rig.base.answered(fixture.ask())
        try fixture.assertLaunchedWithoutToken()
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rig.base.record.path + ".sandbox"))
        try fixture.assertNoPersistedCredentials()
    }
}
