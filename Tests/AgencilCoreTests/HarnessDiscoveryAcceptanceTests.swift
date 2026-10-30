// U4 public API contract (implementation deliberately absent here):
// HarnessCatalog: Decodable; entries: [HarnessCatalog.Entry]. Entry exposes
// kind: String, installHint: String. JSON schema is exercised in catalog(_:).
// HarnessDiscovery.init(); discover(catalog: HarnessCatalog, searchPath: [URL],
// knownInstallDirectories: [URL], environment: [String: String],
// probeTimeout: Duration = .seconds(20)) async throws -> [HarnessProbe].
// HarnessProbe: kind: String, paths: [URL], version: String?, signedIn: SignInState,
// probeStatus: ProbeStatus, chainSupport: ChainSupport.
// SignInState: Equatable, .signedIn, .signedOut, .unknown(reason: String).
// ProbeStatus: Equatable, .ok, .timedOut, .failed(reason: String);
// message: String (timedOut is exactly "probe timed out").
// Existing helpers: AcceptanceDirectory.init() throws, .url: URL, .remove();
// acceptanceCommand(_ argv: [String]) throws -> (Int32, String).
// ChainSupport: Equatable, .supported, .unsupported, .untested.
// Catalog chainProbe argv substitutes {server} with the fixture path specified in
// server, injects a fresh AGENCIL_CHAIN_MARKER, and verifies the child's JSON-RPC
// result matches it. Probes use ProcessRunner, closed stdin and no terminal.
import Foundation
import Darwin
import Testing
import AgencilCore

@Suite struct HarnessDiscoveryAcceptanceTests {
    @Test func explicitPathsVersionsMissingAndIndependentTimeouts() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let extra = temp.url.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try executable("fast", at: temp.url, body: normalHarness("1.2.3"))
        try executable("fast", at: extra, body: normalHarness("2.0.0"))
        try executable("known", at: extra, body: normalHarness("4.5.6"))
        let hanging = ["hang1", "hang2", "hang3"]
        defer {
            // Also clean up if an incorrect implementation fails to kill a probe.
            for name in hanging {
                let file = temp.url.appendingPathComponent(name + ".pid")
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let pid = Int32(text) { kill(pid, SIGKILL) }
            }
        }
        for name in hanging {
            let file = temp.url.appendingPathComponent(name + ".pid")
            try executable(name, at: temp.url,
                body: "printf '%s' \"$$\" > '\(file.path)'; exec /bin/sleep 8")
        }
        let start = ContinuousClock.now
        let results = try await HarnessDiscovery().discover(
            catalog: catalog(["fast", "known", "missing", "hang1", "hang2", "hang3"]),
            searchPath: [temp.url], knownInstallDirectories: [extra], environment: [:],
            probeTimeout: .milliseconds(1500))
        #expect(start.duration(to: .now) < .seconds(4), "Must not wait 8 seconds per hung binary")
        #expect(Set(results.map(\.kind)) == Set(["fast", "known", "missing", "hang1", "hang2", "hang3"]))
        let fast = try #require(results.first { $0.kind == "fast" })
        #expect(Set(fast.paths.map(\.path)) == Set([temp.url.appendingPathComponent("fast").path,
                                                  extra.appendingPathComponent("fast").path]))
        #expect(fast.version == "2.0.0")
        #expect(fast.probeStatus == .ok)
        #expect(fast.signedIn == .signedIn)
        #expect(fast.chainSupport == .untested)
        let known = try #require(results.first { $0.kind == "known" })
        #expect(known.version == "4.5.6")
        #expect(known.probeStatus == .ok)
        let missing = try #require(results.first { $0.kind == "missing" })
        #expect(missing.paths.isEmpty)
        #expect(missing.version == nil)
        #expect(missing.signedIn != .signedIn)
        for result in results where result.kind.hasPrefix("hang") {
            #expect(result.probeStatus == .timedOut)
            #expect(result.probeStatus.message == "probe timed out")
            #expect(result.signedIn != .signedIn)
        }
    }

    @Test func statusUsesClosedStdinNoTTYAndIgnoresDecoyCredentials() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let home = temp.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".stub"),
                                                withIntermediateDirectories: true)
        try Data(#"{"access_token":"valid-looking-decoy"}"#.utf8)
            .write(to: home.appendingPathComponent(".stub/auth.json"))
        let opened = temp.url.appendingPathComponent("browser-opened")
        try executable("open", at: temp.url, body: "printf launched > '\(opened.path)'; exit 99")
        try executable("safe", at: temp.url, body: """
        case "$1" in
          --version) printf '1.0.0';;
          status)
            test "$2" = --non-interactive || { open browser; exit 91; }
            test ! -t 0 && test ! -t 1 || exit 92
            if read answer; then exit 93; fi
            printf 'signed-out'; exit 1;;
          *) exit 94;;
        esac
        """)
        try executable("prompt", at: temp.url, body: """
        case "$1" in
          --version) printf '1.0.0';;
          status) if read answer; then exit 93; fi; printf 'stdin-eof'; exit 2;;
        esac
        """)
        let results = try await HarnessDiscovery().discover(catalog: catalog(["safe", "prompt"]),
            searchPath: [temp.url], knownInstallDirectories: [],
            environment: ["HOME": home.path, "PATH": temp.url.path], probeTimeout: .milliseconds(1500))
        #expect(!FileManager.default.fileExists(atPath: opened.path))
        let safe = try #require(results.first { $0.kind == "safe" })
        #expect(safe.signedIn == .signedOut)
        let prompt = try #require(results.first { $0.kind == "prompt" })
        switch prompt.signedIn {
        case .unknown(let reason): #expect(!reason.isEmpty)
        default: Issue.record("Unrecognized status must fail closed with a reason")
        }
        #expect(prompt.probeStatus != .ok)
    }

    @Test func realStdioChildProvesEnvironmentForwarding() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        for name in ["forward", "scrub"] {
            let launch = name == "forward" ? "exec /bin/sh \"$2\"" :
                "exec /usr/bin/env -i /bin/sh \"$2\""
            try executable(name, at: temp.url, body: """
            case "$1" in
              --version) printf '1.0.0';;
              status) printf 'signed-in';;
              chain) \(launch);;
              *) exit 95;;
            esac
            """)
        }
        let results = try await HarnessDiscovery().discover(
            catalog: catalog(["forward", "scrub"], chain: true), searchPath: [temp.url],
            knownInstallDirectories: [], environment: [:], probeTimeout: .milliseconds(1500))
        let forward = try #require(results.first { $0.kind == "forward" })
        let scrub = try #require(results.first { $0.kind == "scrub" })
        #expect(forward.chainSupport == .supported)
        #expect(scrub.chainSupport == .unsupported)
    }

    @Test func shippedCatalogIsDataWithCompleteAppleSiliconInstallHints() throws {
        let url = repositoryRoot.appendingPathComponent("Sources/AgencilCore/Harness/catalog.json")
        let shipped = try JSONDecoder().decode(HarnessCatalog.self, from: Data(contentsOf: url))
        let kinds = shipped.entries.map(\.kind)
        #expect(Set(kinds).isSuperset(of: ["claude", "codex", "opencode", "hermes",
                                         "gemini", "aider", "goose", "ollama"]))
        #expect(Set(kinds).count == kinds.count)
        for entry in shipped.entries {
            #expect(!entry.installHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!entry.installHint.contains("/usr/local"))
            if entry.installHint.lowercased().contains("brew") {
                #expect(entry.installHint.contains("/opt/homebrew"))
            }
        }
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func catalog(_ names: [String], chain: Bool = false) throws -> HarnessCatalog {
    let server = repositoryRoot.appendingPathComponent("Tests/Fixtures/chain-marker.sh").path
    let entries: [[String: Any]] = names.map { name in
        var entry: [String: Any] = ["kind": name, "executable": name,
            "versionArguments": ["--version"],
            "status": ["arguments": ["status", "--non-interactive"],
                       "signedInOutput": "signed-in", "signedInExitCode": 0,
                       "signedOutOutput": "signed-out", "signedOutExitCode": 1],
            "chainNotes": "Verify stdio child environment forwarding",
            "installHint": "https://example.invalid/install"]
        if chain { entry["chainProbe"] = ["arguments": ["chain", "{server}"], "server": server] }
        return entry
    }
    return try JSONDecoder().decode(HarnessCatalog.self,
        from: JSONSerialization.data(withJSONObject: ["entries": entries]))
}

private func executable(_ name: String, at directory: URL, body: String) throws {
    let path = directory.appendingPathComponent(name)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
    let result = try acceptanceCommand(["/bin/chmod", "700", path.path])
    #expect(result.0 == 0)
}

private func normalHarness(_ version: String) -> String {
    "case \"$1\" in --version) printf '\(version)';; status) printf signed-in;; *) exit 2;; esac"
}
