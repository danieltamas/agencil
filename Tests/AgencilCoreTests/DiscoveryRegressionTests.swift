import Foundation
import Testing
import AgencilCore

/// Cases found by review that the acceptance tests do not cover.
@Suite struct DiscoveryRegressionTests {
    @Test func endpointPolicyRefusesLookalikeHosts() {
        for endpoint in ["HTTP://example.com", "http://127.0.0.1.evil.example", "http://[::ffff:127.0.0.1]:11434",
                         "http://localhost.:11434", "http://127.1", "http://0x7f.0.0.1", "http://2130706433"] {
            #expect(throws: (any Error).self) { try EndpointPolicy.validate(endpoint) }
        }
        #expect(throws: (any Error).self) { try EndpointPolicy.validate("HTTP://example.com") }
        #expect((try? EndpointPolicy.validate("HTTPS://example.com")) != nil)
    }

    @Test func contradictoryStatusIsUnknownEvenWhenTheExitCodeAgrees() async throws {
        let temp = try Self.directory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try Self.script("both", in: temp, body: """
        case "$1" in --version) printf '1.0.0';; status) printf 'signed-in signed-out';; esac
        """)
        let results = try await HarnessDiscovery().discover(catalog: Self.catalog("both"), searchPath: [temp],
            knownInstallDirectories: [], environment: [:], probeTimeout: .seconds(5))
        let probe = try #require(results.first)
        guard case .unknown = probe.signedIn else { Issue.record("Contradictory status must be unknown"); return }
    }

    @Test func releaseOutranksPrereleaseAndTheChosenExecutableIsReported() async throws {
        let temp = try Self.directory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let other = temp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Self.script("tool", in: temp, body: "printf '1.0.0'")
        try Self.script("tool", in: other, body: "printf '1.0.0-beta.2'")
        let results = try await HarnessDiscovery().discover(catalog: Self.catalog("tool"), searchPath: [other, temp],
            knownInstallDirectories: [], environment: [:], probeTimeout: .seconds(5))
        let probe = try #require(results.first)
        #expect(probe.version == "1.0.0")
        #expect(probe.executable?.path == temp.appendingPathComponent("tool").path)
    }

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func script(_ name: String, in directory: URL, body: String) throws {
        let path = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
        #expect(chmod(path.path, 0o700) == 0)
    }

    private static func catalog(_ name: String) throws -> HarnessCatalog {
        let json = """
        {"entries":[{"kind":"\(name)","executable":"\(name)","versionArguments":["--version"],
        "status":{"arguments":["status"],"signedInOutput":"signed-in","signedInExitCode":0,
        "signedOutOutput":"signed-out","signedOutExitCode":0},"chainNotes":"","installHint":"x"}]}
        """
        return try HarnessCatalog.decode(Data(json.utf8))
    }
}
