import AgencilCore
import Foundation
import Testing

private struct U17Fixture {
    let home: BrokerHome
    let environment: [String: String]
    let instruction: AgentInstruction
    let access: AgentAccess

    init() throws {
        home = try BrokerHome()
        environment = ["HOME": home.url.path, "AGENCIL_HOME": home.url.path,
                       "AGENCIL_MCP_CONFIG_DIR": home.url.appendingPathComponent("harnesses").path,
                       "PATH": "/usr/bin:/bin"]
        instruction = AgentInstruction(home: home.url, environment: environment)
        access = AgentAccess(home: home.url, environment: environment)
    }

    func put(_ text: String, harness: String) throws {
        let path = instruction.path(harness)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }

    func bytes(_ harness: String) throws -> Data { try Data(contentsOf: instruction.path(harness)) }

    func values(on: Bool = true, routed: Bool = false) -> [String: String] {
        ["agent_access": on ? "on" : "off",
         "seats": "[{\"name\":\"reviewer\",\"harness\":\"codex\",\"model\":\"test-model\"}]",
         "routes": routed ? "[{\"callers\":[\"codex\"],\"target\":\"reviewer\",\"hop_limit\":1}]" : "[]"]
    }
}

@Suite struct U17AgentAccessAcceptanceTests {
    private let begin = "<!-- agencil:begin v1 -->"
    private let end = "<!-- agencil:end -->"
    private let harnesses = ["claude", "codex", "opencode"]

    @Test func instructionTextMeetsPublishedContract() {
        let text = AgentInstruction.text
        #expect(text.utf8.allSatisfy { $0 < 128 })
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count <= 12)
        #expect(text.hasPrefix(begin))
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(end))
        #expect(text.components(separatedBy: begin).count == 2)
        #expect(text.components(separatedBy: end).count == 2)
        for term in ["ask", "wake_council", "ask_result", "second opinion", "review", "question",
                     "stronger", "different", "repo", "seat", "evidence", "instructions"] {
            #expect(text.lowercased().contains(term), "Missing instruction concept: \(term)")
        }
    }

    @Test func documentedPathsRespectOverrideAndHome() throws {
        let f = try U17Fixture()
        let relative = ["claude": "claude/rules/agencil.md", "codex": "codex/AGENTS.md",
                        "opencode": "opencode/AGENTS.md"]
        let real = ["claude": ".claude/rules/agencil.md", "codex": ".codex/AGENTS.md",
                    "opencode": ".config/opencode/AGENTS.md"]
        let plain = AgentInstruction(home: f.home.url, environment: [:])
        for harness in harnesses {
            #expect(f.instruction.path(harness).standardizedFileURL ==
                    f.home.url.appendingPathComponent("harnesses/" + relative[harness]!).standardizedFileURL)
            #expect(plain.path(harness).standardizedFileURL ==
                    f.home.url.appendingPathComponent(real[harness]!).standardizedFileURL)
        }
    }

    // Acceptance 1 and 5: a new file is exactly the block, stable on reinstall, deleted on removal.
    @Test(arguments: ["claude", "codex", "opencode"])
    func newFileIsIdempotentAndRemovedWhenEmpty(harness: String) throws {
        let f = try U17Fixture()
        try f.instruction.install(harness)
        let first = try f.bytes(harness)
        #expect(first == Data(AgentInstruction.text.utf8))
        try f.instruction.install(harness)
        #expect(try f.bytes(harness) == first)
        try f.instruction.remove(harness)
        #expect(!FileManager.default.fileExists(atPath: f.instruction.path(harness).path))
        try f.instruction.remove(harness)
        #expect(!FileManager.default.fileExists(atPath: f.instruction.path(harness).path))
    }

    // Acceptance 2: appended blocks round-trip even whitespace and a missing final newline.
    @Test(arguments: ["claude", "codex", "opencode"])
    func userBytesSurviveAppendAndRemove(harness: String) throws {
        let f = try U17Fixture()
        for original in ["# User rules\nKeep this.\n", "# User rules\nKeep this.", "# Rules\n\n\tKeep spaces.  \n\n"] {
            try f.put(original, harness: harness)
            try f.instruction.remove(harness)
            #expect(try f.bytes(harness) == Data(original.utf8))
            try f.instruction.install(harness)
            let installed = try f.bytes(harness)
            #expect(installed.starts(with: Data(original.utf8)))
            #expect(String(decoding: installed, as: UTF8.self).components(separatedBy: begin).count == 2)
            try f.instruction.remove(harness)
            #expect(try f.bytes(harness) == Data(original.utf8))
        }
    }

    // Acceptance 2 and 3: replacement and removal preserve both sides of an existing block.
    @Test(arguments: ["claude", "codex", "opencode"])
    func outdatedBlockUpgradesInPlace(harness: String) throws {
        let f = try U17Fixture()
        let prefix = "# User rules\nKeep this spacing.  \n"
        let suffix = "\n# More user rules\n\tKeep this too.\n"
        let old = begin + "\nOld instruction text.\n" + end
        try f.put(prefix + "\n" + old + suffix, harness: harness)
        #expect(f.instruction.state(harness) == .outdated)
        try f.instruction.install(harness)
        #expect(try f.bytes(harness) == Data((prefix + "\n" + AgentInstruction.text + suffix).utf8))
        #expect(f.instruction.state(harness) == .current)
        try f.instruction.remove(harness)
        #expect(try f.bytes(harness) == Data((prefix + suffix).utf8))
    }

    // Acceptance 4 and the duplicate-block refusal: neither mutation may guess at ownership.
    @Test(arguments: ["claude", "codex", "opencode"])
    func brokenMarkersRefuseWithoutChangingBytes(harness: String) throws {
        let f = try U17Fixture()
        for malformed in [begin + "\nunfinished", "user text\n" + end,
                          end + "\n" + begin,
                          AgentInstruction.text + "\n" + AgentInstruction.text] {
            try f.put(malformed, harness: harness)
            #expect(f.instruction.state(harness) == .broken)
            for operation in [f.instruction.install, f.instruction.remove] {
                #expect(throws: (any Error).self) { try operation(harness) }
                #expect(try f.bytes(harness) == Data(malformed.utf8))
            }
        }
    }

    // Acceptance 6: state is a fresh read, including an ordinary user file without markers.
    @Test(arguments: ["claude", "codex", "opencode"])
    func stateTracksActualFile(harness: String) throws {
        let f = try U17Fixture()
        #expect(f.instruction.state(harness) == .absent)
        try f.put("# Only user rules\n", harness: harness)
        #expect(f.instruction.state(harness) == .absent)
        try f.instruction.install(harness)
        #expect(f.instruction.state(harness) == .current)
        try f.put(begin + "\nOld text\n" + end, harness: harness)
        #expect(f.instruction.state(harness) == .outdated)
        try f.put(begin, harness: harness)
        #expect(f.instruction.state(harness) == .broken)
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func foreignOwnedSymlinkIsRefused(harness: String) throws {
        let f = try U17Fixture(), target = URL(fileURLWithPath: "/etc/hosts")
        let original = try Data(contentsOf: target)
        let path = f.instruction.path(harness)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        #expect(throws: (any Error).self) { try f.instruction.install(harness) }
        #expect(try Data(contentsOf: target) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == target.path)
    }

    // Acceptance 7: exercise the real MCP config and fresh instruction reads, without a broker.
    @Test func auditReportsWiringAndEachDriftCondition() throws {
        let f = try U17Fixture()
        let empty = f.access.audit(values: f.values())
        #expect(Set(empty.map(\.harness)) == Set(harnesses))
        #expect(empty.count == harnesses.count)
        #expect(empty.allSatisfy { !$0.mcp.installed && $0.instruction == .absent && $0.drift.isEmpty })
        _ = try f.access.install("codex")
        var row = try #require(f.access.audit(values: f.values()).first { $0.harness == "codex" })
        #expect(row.mcp.installed && row.instruction == .absent && row.caller == "codex")
        #expect(row.routes.isEmpty)
        #expect(Set(row.drift) == ["instructions missing", "no route for this caller"])
        try f.instruction.install("codex")
        row = try #require(f.access.audit(values: f.values(routed: true)).first { $0.harness == "codex" })
        #expect(row.instruction == .current && row.mcp.installed)
        #expect(row.routes == ["reviewer"] && row.drift.isEmpty)
        let others = f.access.audit(values: f.values(routed: true)).filter { $0.harness != "codex" }
        #expect(others.allSatisfy { $0.routes.isEmpty && $0.drift.isEmpty })
        row = try #require(f.access.audit(values: f.values(on: false, routed: true)).first { $0.harness == "codex" })
        #expect(row.drift == ["access is off"])
        try f.put(begin + "\nOld text\n" + end, harness: "codex")
        row = try #require(f.access.audit(values: f.values(routed: true)).first { $0.harness == "codex" })
        #expect(row.drift == ["instructions outdated"])
        try f.instruction.install("codex")
        _ = try f.access.uninstall("codex")
        row = try #require(f.access.audit(values: f.values()).first { $0.harness == "codex" })
        #expect(!row.mcp.installed && row.instruction == .current)
        #expect(row.drift == ["instructions without server"])
    }

    @Test func auditDetectsForeignServerCommand() throws {
        let f = try U17Fixture()
        let file = f.home.url.appendingPathComponent("harnesses/codex/config.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[mcp_servers.agencil]\ncommand = \"/usr/bin/false\"\nargs = [\"mcp\", \"--caller\", \"codex\"]\n".utf8).write(to: file)
        try f.instruction.install("codex")
        let row = try #require(f.access.audit(values: f.values(routed: true)).first { $0.harness == "codex" })
        #expect(row.mcp.installed)
        #expect(row.drift == ["server entry does not match this app"])
    }

    // Acceptance 8: direct CLI invocation, isolated home, no server process or socket.
    @Test func offlineCLIAndDryRunSucceedWithoutWritingInstructions() throws {
        let f = try U17Fixture()
        let cli = CommandLineTool(environment: f.environment)
        #expect(cli.run(["access", "--json"]) == 0)
        #expect(cli.run(["access"]) == 0)
        for harness in harnesses {
            #expect(cli.run(["install-instructions", harness, "--dry-run"]) == 0)
            #expect(!FileManager.default.fileExists(atPath: f.instruction.path(harness).path))
            try f.put("# Preserve user rules\n", harness: harness)
            let before = try f.bytes(harness)
            #expect(cli.run(["install-instructions", harness, "--dry-run", "--json"]) == 0)
            #expect(try f.bytes(harness) == before)
        }
    }

    // Acceptance 9: an unknown harness is a usage error, also on the dry-run path.
    @Test func unsupportedInstructionHarnessExits64() throws {
        let f = try U17Fixture()
        let cli = CommandLineTool(environment: f.environment)
        for flags in [[], ["--dry-run"], ["--uninstall"], ["--json"]] {
            #expect(cli.run(["install-instructions", "unsupported"] + flags) == 64)
        }
    }
}
