import AgencilCore
import Foundation
import Testing

private struct Sandbox26Fixture {
    let home: BrokerHome
    let settings: URL
    let argv: URL
    let environment: [String: String]

    init() throws {
        home = try BrokerHome()
        settings = home.url.appendingPathComponent("claude/settings.json")
        argv = home.url.appendingPathComponent("claude-argv")
        let bin = home.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: brokerFixture("u5-claude.sh"), to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        environment = [
            "AGENCIL_MCP_CONFIG_DIR": home.url.path,
            "CLAUDE_ARGV": argv.path,
            "PATH": bin.path + ":/usr/bin:/bin"
        ]
    }

    func run(_ flags: [String] = []) throws -> (Int32, String, String) {
        try home.cli(["install-mcp", "claude"] + flags, env: environment)
    }

    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: settings)
    }

    func bytes() throws -> Data { try Data(contentsOf: settings) }

    func object() throws -> [String: Any] { try brokerJSON(bytes()) }

    func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    func writeServer(command: String = NSHomeDirectory() + "/.local/bin/agencil") throws {
        let object: [String: Any] = [
            "mcpServers": [
                "agencil": ["command": command, "args": ["mcp", "--caller", "claude"]]
            ]
        ]
        let file = home.url.appendingPathComponent("claude/claude.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    func audit() throws -> Wiring {
        let access = AgentAccess(home: home.url, environment: environment)
        return try #require(access.audit(values: [
            "agent_access": "on", "seats": "[]", "routes": "[]"
        ]).first { $0.harness == "claude" })
    }

    func additions() throws -> [[String: String]] {
        let file = home.url.appendingPathComponent("installed.json")
        let root = try brokerJSON(Data(contentsOf: file))
        let claude = try #require((root["entries"] as? [String: Any])?["claude"] as? [String: Any])
        return claude["sandbox"] as? [[String: String]] ?? []
    }
}

private let sandbox26Write = "~/.agencil"
// Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
private let sandbox26Socket = "~/.agencil/agent.sock"

private func sandbox26Settings(write: Bool = false, socket: Bool = false,
                               enabled: Bool = true) -> [String: Any] {
    [
        "owner": ["name": "maya", "preferences": [true, false, 17]],
        "permissions": ["allow": ["Read"], "deny": ["Edit"]],
        "sandbox": [
            "enabled": enabled,
            "ownerOption": ["keep": "unchanged"],
            "filesystem": [
                "allowWrite": ["~/harbor", "~/lumen"] + (write ? [sandbox26Write] : []),
                "denyRead": ["~/private"]
            ],
            "network": [
                "allowUnixSockets": ["~/harbor/service.sock"] + (socket ? [sandbox26Socket] : []),
                "allowedDomains": ["example.invalid"]
            ]
        ]
    ]
}

private func sandbox26Canonical(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func sandbox26Arrays(_ object: [String: Any]) throws -> ([String], [String]) {
    let sandbox = try #require(object["sandbox"] as? [String: Any])
    let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
    let network = try #require(sandbox["network"] as? [String: Any])
    return (try #require(filesystem["allowWrite"] as? [String]),
            try #require(network["allowUnixSockets"] as? [String]))
}

@Suite struct Sandbox26AcceptanceTests {
    @Test(arguments: [false, true], [0, 1, 2, 3])
    func legacyRecordedPairIsMigratedOrUninstalled(uninstall: Bool, ownerMask: Int) throws {
        let f = try Sandbox26Fixture()
        try f.write(sandbox26Settings())
        #expect(try f.run().0 == 0)
        // Preserve the install record's real envelope and key vocabulary; simulate the old recorded pair.
        let addition = try #require(f.additions().first { $0["value"] == sandbox26Socket })
        let socketKey = try #require(addition["key"])
        let writeKey = socketKey.replacingOccurrences(of: "network", with: "filesystem")
            .replacingOccurrences(of: "allowUnixSockets", with: "allowWrite")
        #expect(writeKey != socketKey)
        let oldSocket = "~/.agencil/agencil.sock"
        let ownerWrite = ownerMask & 1 != 0, ownerSocket = ownerMask & 2 != 0
        var original = sandbox26Settings(write: true)
        var sandbox = try #require(original["sandbox"] as? [String: Any])
        var network = try #require(sandbox["network"] as? [String: Any])
        network["allowUnixSockets"] = ["~/harbor/service.sock", oldSocket]
        sandbox["network"] = network; original["sandbox"] = sandbox
        try f.write(original)
        let record = f.home.url.appendingPathComponent("installed.json")
        var root = try brokerJSON(Data(contentsOf: record))
        var entries = try #require(root["entries"] as? [String: Any])
        var claude = try #require(entries["claude"] as? [String: Any])
        var recorded: [[String: String]] = []
        if !ownerSocket { recorded.append(["key": socketKey, "value": oldSocket, "file": f.settings.path]) }
        if !ownerWrite { recorded.append(["key": writeKey, "value": sandbox26Write, "file": f.settings.path]) }
        claude["sandbox"] = recorded; entries["claude"] = claude; root["entries"] = entries
        try JSONSerialization.data(withJSONObject: root).write(to: record)
        #expect(try f.run(uninstall ? ["--uninstall"] : []).0 == 0)
        let (writes, sockets) = try sandbox26Arrays(f.object())
        #expect(writes == ["~/harbor", "~/lumen"] + (ownerWrite ? [sandbox26Write] : []))
        #expect(sockets == ["~/harbor/service.sock"] + (ownerSocket ? [oldSocket] : []) +
            (uninstall ? [] : [sandbox26Socket]))
        if !uninstall {
            #expect(try f.run(["--uninstall"]).0 == 0)
            let remaining = try sandbox26Arrays(f.object())
            #expect(remaining.0 == writes)
            #expect(remaining.1 == ["~/harbor/service.sock"] + (ownerSocket ? [oldSocket] : []))
        }
    }

    // A1: Claude starts the command directly, so shell tilde expansion cannot help.
    @Test func dryRunAndRealArgvUseExpandedExecutable() throws {
        let f = try Sandbox26Fixture()
        let (code, output, _) = try f.run(["--dry-run"])
        #expect(code == 0)
        let line = try #require(output.split(separator: "\n").first {
            $0.contains("mcp add agencil")
        })
        #expect(line.contains(NSHomeDirectory() + "/.local/bin/agencil"))
        #expect(!line.contains("~"))
        #expect(!FileManager.default.fileExists(atPath: f.argv.path))
        #expect(try f.run().0 == 0)
        let args = try String(contentsOf: f.argv, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(args.count == 10)
        #expect(Array(args.prefix(6)) == ["mcp", "add", "agencil", "--scope", "user", "--"])
        #expect(try #require(args.indices.contains(6) ? args[6] : nil) ==
                NSHomeDirectory() + "/.local/bin/agencil")
        #expect(Array(args.suffix(3)) == ["mcp", "--caller", "claude"])
    }

    // A2: compare the entire parsed object, including array order and unrelated keys.
    @Test func installAddsOnlyRequiredValuesAndKeepsMode() throws {
        let f = try Sandbox26Fixture()
        try f.write(sandbox26Settings())
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.settings.path)
        let mode = try f.permissions()
        #expect(try f.run().0 == 0)
        // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
        #expect(try sandbox26Canonical(f.object()) ==
                sandbox26Canonical(sandbox26Settings(socket: true)))
        #expect(try f.permissions() == mode)
        let additions = try f.additions()
        // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
        #expect(additions.count == 1)
        #expect(Set(additions.compactMap { $0["value"] }) ==
                Set([sandbox26Socket]))
        #expect(additions.allSatisfy { !($0["key"] ?? "").isEmpty })
    }

    // A2: absent nested dictionaries must be created without losing sibling settings.
    @Test func installCreatesMissingPermissionArrays() throws {
        let f = try Sandbox26Fixture()
        try f.write(["owner": "maya", "sandbox": ["enabled": true, "keep": 7]])
        #expect(try f.run().0 == 0)
        let expected: [String: Any] = [
            "owner": "maya",
            "sandbox": [
                "enabled": true, "keep": 7,
                // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
                "network": ["allowUnixSockets": [sandbox26Socket]]
            ]
        ]
        #expect(try sandbox26Canonical(f.object()) == sandbox26Canonical(expected))
    }

    // A3: a repeated install must neither duplicate values nor lose their ownership.
    @Test func installingTwiceIsIdempotent() throws {
        let f = try Sandbox26Fixture()
        try f.write(sandbox26Settings())
        #expect(try f.run().0 == 0)
        let first = try sandbox26Canonical(f.object())
        #expect(try f.run().0 == 0)
        #expect(try sandbox26Canonical(f.object()) == first)
        let (writes, sockets) = try sandbox26Arrays(f.object())
        // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
        #expect(writes.filter { $0 == sandbox26Write }.isEmpty)
        #expect(sockets.filter { $0 == sandbox26Socket }.count == 1)
        #expect(try f.run(["--uninstall"]).0 == 0)
        #expect(try sandbox26Canonical(f.object()) == sandbox26Canonical(sandbox26Settings()))
    }

    // A4: only the JSON boolean true enables changes.
    @Test(arguments: [
        "{\"sandbox\":{\"enabled\":false},\"owner\":\"maya\"}\n",
        "{\"sandbox\":{},\"owner\":\"maya\"}\n",
        "{\"sandbox\":{\"enabled\":\"true\"}}\n",
        "{\"sandbox\":{\"enabled\":1}}\n",
        "{broken\n",
        "[]\n",
        "null\n"
    ])
    func inactiveOrInvalidSettingsAreByteEqual(text: String) throws {
        let f = try Sandbox26Fixture(), original = Data(text.utf8)
        try original.write(to: f.settings)
        #expect(try f.run().0 == 0)
        #expect(try f.bytes() == original)
    }

    @Test func absentSettingsStayAbsent() throws {
        let f = try Sandbox26Fixture()
        #expect(try f.run().0 == 0)
        #expect(!FileManager.default.fileExists(atPath: f.settings.path))
    }

    // A5: exercise both values independently, including mixed ownership.
    @Test(arguments: [0, 1, 2, 3])
    func uninstallRemovesOnlyRecordedAdditions(ownerMask: Int) throws {
        let f = try Sandbox26Fixture()
        let ownerWrite = ownerMask & 1 != 0, ownerSocket = ownerMask & 2 != 0
        let original = sandbox26Settings(write: ownerWrite, socket: ownerSocket)
        try f.write(original)
        #expect(try f.run().0 == 0)
        // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
        #expect(try sandbox26Canonical(f.object()) ==
                sandbox26Canonical(sandbox26Settings(write: ownerWrite, socket: true)))
        let additions = try f.additions()
        // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
        let expectedValues = ownerSocket ? [] : [sandbox26Socket]
        #expect(additions.count == expectedValues.count)
        #expect(Set(additions.compactMap { $0["value"] }) == Set(expectedValues))
        #expect(additions.allSatisfy { !($0["key"] ?? "").isEmpty })
        #expect(try f.run(["--uninstall"]).0 == 0)
        #expect(try sandbox26Canonical(f.object()) == sandbox26Canonical(original))
    }

    // A6: the same audit instance reads the current file on every call.
    @Test func auditReportsOnlyEnabledInstalledSandboxWithMissingValues() throws {
        let f = try Sandbox26Fixture()
        try f.write(sandbox26Settings())
        try f.writeServer()
        #expect(try !f.audit().mcp.installed)
        #expect(try !f.audit().drift.contains("sandbox blocks Agencil"))
        #expect(try f.run().0 == 0)
        try f.writeServer()
        #expect(try f.audit().mcp.installed)
        let access = AgentAccess(home: f.home.url, environment: f.environment)
        for mask in 0...3 {
            try f.write(sandbox26Settings(write: mask & 1 != 0, socket: mask & 2 != 0))
            let row = try #require(access.audit(values: [
                "agent_access": "on", "seats": "[]", "routes": "[]"
            ]).first { $0.harness == "claude" })
            #expect(row.mcp.installed)
            // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
            #expect(row.drift.contains("sandbox blocks Agencil") == (mask & 2 == 0))
        }
        try f.write(sandbox26Settings(enabled: false))
        #expect(try !f.audit().drift.contains("sandbox blocks Agencil"))
        try FileManager.default.removeItem(at: f.settings)
        #expect(try !f.audit().drift.contains("sandbox blocks Agencil"))
    }

    @Test func auditTreatsLegacyTildeCommandAsDrift() throws {
        let f = try Sandbox26Fixture()
        #expect(try f.run().0 == 0)
        try f.writeServer(command: "~/.local/bin/agencil")
        #expect(try f.audit().mcp.installed)
        #expect(try f.audit().drift.contains("server entry does not match this app"))
        try f.writeServer()
        #expect(try !f.audit().drift.contains("server entry does not match this app"))
    }

    // Behaviour 7: repair a manual removal even when the MCP entry is already installed.
    @Test func reinstallRepairsManuallyRemovedSandboxValues() throws {
        let f = try Sandbox26Fixture()
        try f.write(sandbox26Settings())
        #expect(try f.run().0 == 0)
        try f.writeServer()
        try f.write(sandbox26Settings())
        #expect(try f.audit().drift.contains("sandbox blocks Agencil"))
        #expect(try f.run().0 == 0)
        // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
        #expect(try sandbox26Canonical(f.object()) ==
                sandbox26Canonical(sandbox26Settings(socket: true)))
        #expect(try !f.audit().drift.contains("sandbox blocks Agencil"))
    }

    // Behavior change: Claude sandbox gets only the agent socket, no allowWrite (docs/U32-SPEC.md 3)
    @Test func dryRunPrintsSandboxAdditionsWithoutWriting() throws {
        let f = try Sandbox26Fixture()
        try f.write(sandbox26Settings())
        let original = try f.bytes(), mode = try f.permissions()
        let (code, output, _) = try f.run(["--dry-run"])
        #expect(code == 0)
        let lines = output.split(separator: "\n")
        #expect(!lines.contains { $0.contains("allowWrite") })
        #expect(lines.contains {
            $0.contains("allowUnixSockets") && $0.contains(sandbox26Socket)
        })
        #expect(try f.bytes() == original)
        #expect(try f.permissions() == mode)
        #expect(!FileManager.default.fileExists(atPath: f.argv.path))
        #expect(!FileManager.default.fileExists(
            atPath: f.home.url.appendingPathComponent("installed.json").path))
    }
}
