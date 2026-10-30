// Config-location override and file names are declared in BrokerAcceptanceSupport.swift.
// installed.json is parsed recursively: at least one 64-character hex entry hash is required.
// TOML validation uses Python 3.11+ tomllib, an independent parser, never product code.
import Foundation
import Darwin
import Testing

private struct InstallFixture {
    let home: BrokerHome
    let kind: String
    let file: URL
    let original: Data
    var env: [String: String] { ["AGENCIL_MCP_CONFIG_DIR": home.url.path] }
    init(_ kind: String) throws {
        home = try BrokerHome(); self.kind = kind
        file = home.url.appendingPathComponent(kind == "codex" ? "codex/config.toml" : "opencode/opencode.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let padding = String(repeating: "preserve me ", count: 20_000)
        original = Data((kind == "codex" ? "# preserve comment\nowner = \"maya\"\npadding = \"\(padding)\"\n"
                         : "{\n  \"owner\": \"maya\",\n  \"padding\": \"\(padding)\"\n}\n").utf8)
        try original.write(to: file)
    }
    func run(_ flags: [String] = []) throws -> (Int32, String, String) {
        try home.cli(["install-mcp", kind] + flags, env: env)
    }
    func bytes() throws -> Data { try Data(contentsOf: file) }
    func modified() throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    }
    func record() throws -> Data { try Data(contentsOf: home.url.appendingPathComponent("installed.json")) }
    func appendForeignEntry() throws {
        let text = kind == "codex" ? "[mcp_servers.agencil]\ncommand = \"foreign\"\nargs = []\n"
            : ",\n  \"mcp\": {\"agencil\": {\"type\": \"local\", \"command\": [\"foreign\"]}}\n}"
        let bytes = kind == "codex" ? original + Data(text.utf8) : original.dropLast(2) + Data(text.utf8)
        try Data(bytes).write(to: file)
    }
}

private func installHashes(_ object: Any) -> [String] {
    if let value = object as? String, value.count == 64,
       value.allSatisfy({ $0.isHexDigit }) { return [value] }
    if let values = object as? [String: Any] { return values.values.flatMap(installHashes) }
    if let values = object as? [Any] { return values.flatMap(installHashes) }
    return []
}

@Suite struct BrokerAcceptanceTestsInstall {
    @Test(arguments: ["codex", "opencode"])
    func dryRunPrintsDiffAndPreservesBytesMtimeAndRecord(kind: String) throws {
        let f = try InstallFixture(kind), before = try f.modified()
        let (code, output, _) = try f.run(["--dry-run"])
        #expect(code == 0)
        #expect(output.contains("agencil"))
        #expect(output.split(separator: "\n").contains { $0.hasPrefix("+") })
        #expect(try f.bytes() == f.original)
        #expect(try f.modified() == before)
        #expect(!FileManager.default.fileExists(atPath: f.home.url.appendingPathComponent("installed.json").path))
    }

    @Test(arguments: ["codex", "opencode"])
    func installRecordsHashAndUninstallRestoresExactOriginal(kind: String) throws {
        let f = try InstallFixture(kind)
        #expect(try f.run().0 == 0)
        let installed = try f.bytes()
        let record = try JSONSerialization.jsonObject(with: f.record())
        let hashes = installHashes(record)
        #expect(!hashes.isEmpty)
        // Check original payload byte sequences, including whitespace, survive insertion.
        let originalText = String(decoding: f.original, as: UTF8.self)
        let installedText = String(decoding: installed, as: UTF8.self)
        if kind == "codex" { #expect(installed.starts(with: f.original)) }
        else {
            for line in originalText.split(separator: "\n").filter({ $0.contains("owner") || $0.contains("padding") }) {
                #expect(installedText.contains(line))
            }
        }
        #expect(installedText.contains("agencil"))
        #expect(try f.run(["--caller", "lee"]).0 == 0)
        #expect(String(decoding: try f.bytes(), as: UTF8.self).contains("lee"))
        let replaced = try JSONSerialization.jsonObject(with: f.record())
        #expect(installHashes(replaced) != hashes)
        #expect(try f.run(["--uninstall"]).0 == 0)
        #expect(try f.bytes() == f.original)
    }

    @Test(arguments: ["codex", "opencode"])
    func foreignEntryIsRefusedAndNeverChanged(kind: String) throws {
        let f = try InstallFixture(kind)
        try f.appendForeignEntry()
        let before = try f.bytes(), mtime = try f.modified()
        let (code, out, error) = try f.run()
        #expect(code != 0)
        #expect(!(out + error).isEmpty)
        #expect(try f.bytes() == before)
        #expect(try f.modified() == mtime)
    }

    @Test(arguments: ["codex", "opencode"])
    func userEditedEntryIsRefusedForBothReinstallAndUninstall(kind: String) throws {
        let f = try InstallFixture(kind)
        #expect(try f.run().0 == 0)
        let installed = String(decoding: try f.bytes(), as: UTF8.self)
        // Change the entry itself, not an unrelated field.
        #expect(installed.contains("--caller"))
        let changed = installed.replacingOccurrences(of: "--caller", with: "--edited-caller")
        try Data(changed.utf8).write(to: f.file)
        let before = try f.bytes(), record = try f.record()
        for flags in [["--caller", "jonas"], ["--uninstall"]] {
            let (code, out, error) = try f.run(flags)
            #expect(code != 0)
            #expect(!(out + error).isEmpty)
            #expect(try f.bytes() == before)
            #expect(try f.record() == record)
        }
    }

    @Test(arguments: ["codex", "opencode"])
    func malformedConfigRemainsUntouchedAndReported(kind: String) throws {
        let f = try InstallFixture(kind)
        try Data((kind == "codex" ? "[broken\n" : "{broken").utf8).write(to: f.file)
        let before = try f.bytes(), mtime = try f.modified()
        let (code, out, error) = try f.run()
        #expect(code != 0)
        #expect(!(out + error).isEmpty)
        #expect(try f.bytes() == before)
        #expect(try f.modified() == mtime)
    }

    @Test(arguments: ["codex", "opencode"])
    func foreignOwnedSymlinkRemainsUntouchedAndReported(kind: String) throws {
        let f = try InstallFixture(kind), target = URL(fileURLWithPath: "/etc/hosts")
        let before = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        let (code, out, error) = try f.run()
        #expect(code != 0)
        #expect(!(out + error).isEmpty)
        #expect(try Data(contentsOf: target) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.file.path) == target.path)
    }

    @Test(arguments: ["codex", "opencode"])
    func concurrentReadersSeeOnlyParseableAtomicWrites(kind: String) throws {
        let f = try InstallFixture(kind)
        let ready = f.home.url.appendingPathComponent("reader-ready")
        let done = f.home.url.appendingPathComponent("reader-done")
        let reader = try BrokerProcess(["python3", brokerFixture("u5-config-reader.py").path, f.file.path, ready.path, done.path, kind],
                                      home: f.home.url, executable: URL(fileURLWithPath: "/usr/bin/env"))
        defer { reader.kill() }
        try brokerPoll { FileManager.default.fileExists(atPath: ready.path) || !reader.process.isRunning }
        guard reader.process.isRunning else {
            let result = try reader.finish()
            throw BrokerFailure("Independent parser reader failed (requires Python 3.11+): \(result)")
        }
        for caller in ["maya", "jonas", "lee"] { #expect(try f.run(["--caller", caller]).0 == 0) }
        try Data().write(to: done)
        let (code, count, error) = try reader.finish()
        #expect(code == 0, "\(error)")
        #expect((Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0)
    }

    @Test(arguments: ["codex", "opencode"])
    func simultaneousInstallersSerializeUnderLock(kind: String) throws {
        let f = try InstallFixture(kind)
        let first = try BrokerProcess(["install-mcp", kind, "--caller", "maya"], home: f.home.url, env: f.env)
        let second = try BrokerProcess(["install-mcp", kind, "--caller", "lee"], home: f.home.url, env: f.env)
        #expect(try first.finish().0 == 0)
        #expect(try second.finish().0 == 0)
        #expect(!installHashes(try JSONSerialization.jsonObject(with: f.record())).isEmpty)
        // A later replace proves that the final file and ownership hash agree.
        #expect(try f.run(["--caller", "jonas"]).0 == 0)
        #expect(try f.run(["--uninstall"]).0 == 0)
        #expect(try f.bytes() == f.original)
    }

    @Test func claudeInstallUsesDocumentedCommandExactly() throws {
        let home = try BrokerHome(), bin = home.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("claude"), argv = home.url.appendingPathComponent("argv")
        try FileManager.default.copyItem(at: brokerFixture("u5-claude.sh"), to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let (code, _, _) = try home.cli(["install-mcp", "claude"], env: [
            "AGENCIL_MCP_CONFIG_DIR": home.url.path, "CLAUDE_ARGV": argv.path,
            "PATH": bin.path + ":/usr/bin:/bin"])
        #expect(code == 0)
        let args = try String(contentsOf: argv, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.count == 10)
        #expect(Array(args.prefix(7)) == ["mcp", "add", "agencil", "--scope", "user", "--", "~/.local/bin/agencil"])
        #expect(Array(args.suffix(3)) == ["mcp", "--caller", "claude"])
    }
}
