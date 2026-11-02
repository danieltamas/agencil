import CryptoKit
import Darwin
import Foundation

/// `agencil install-mcp <harness>`: writes, verifies and removes the `agencil` MCP entry in a harness config.
/// The user's file is edited as text at a recorded position: the inserted text and its hash go to
/// `installed.json`, so uninstall can prove the entry is still exactly what Agencil wrote, and removing it
/// restores the original bytes.
struct McpInstaller {
    struct Refusal: Error { let message: String }

    private let home: AgencilHome
    private let environment: [String: String]

    init(home: AgencilHome, environment: [String: String]) {
        self.home = home
        self.environment = environment
    }

    private var recordURL: URL { home.directory.appendingPathComponent("installed.json") }
    private var command: String { "\(NSHomeDirectory())/.local/bin/agencil" }

    /// Whether `installed.json` records a claude entry written by Agencil.
    var recordsClaude: Bool { ((try? readRecord()) ?? [:])["claude"] != nil }

    func run(harness: String, caller: String?, dryRun: Bool, uninstall: Bool) throws -> Int32 {
        do { return try perform(harness: harness, caller: caller, dryRun: dryRun, uninstall: uninstall) }
        catch let refusal as Refusal {
            FileHandle.standardError.write(Data("agencil: \(refusal.message)\n".utf8))
            return 3
        }
    }

    /// The install or removal itself; a refusal is thrown, so a caller other than the CLI can show its message.
    func perform(harness: String, caller: String?, dryRun: Bool, uninstall: Bool) throws -> Int32 {
        guard ["claude", "codex", "opencode", "hermes"].contains(harness) else {
            throw CommandLineTool.Usage(message: "install-mcp supports claude, codex, opencode and hermes")
        }
        guard harness != "hermes" else {
            throw CommandLineTool.Usage(message: "install-mcp hermes: its config format is verified in U6; paste `agencil mcp --caller hermes` into its MCP config")
        }
        let lock = open(home.directory.appendingPathComponent("install.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw Refusal(message: "cannot take the install lock") }
        defer { close(lock) }
        return harness == "claude"
            ? try runClaude(caller: caller ?? "claude", dryRun: dryRun, uninstall: uninstall)
            : try runFile(harness, caller: caller ?? harness, dryRun: dryRun, uninstall: uninstall)
    }

    // MARK: file-based harnesses (codex TOML, opencode JSON)

    func location(_ harness: String) -> URL {
        if harness == "claude" { return claudeConfig }
        if let base = environment["AGENCIL_MCP_CONFIG_DIR"], !base.isEmpty {
            return URL(fileURLWithPath: base).appendingPathComponent(harness == "codex" ? "codex/config.toml" : "opencode/opencode.json")
        }
        let user = FileManager.default.homeDirectoryForCurrentUser
        return harness == "codex" ? user.appendingPathComponent(".codex/config.toml") : user.appendingPathComponent(".config/opencode/opencode.json")
    }

    private func runFile(_ harness: String, caller: String, dryRun: Bool, uninstall: Bool) throws -> Int32 {
        let path = try writablePath(location(harness))
        let existed = FileManager.default.fileExists(atPath: path.path)
        let original = existed ? try Data(contentsOf: path) : Data()
        guard let text = String(data: original, encoding: .utf8), parses(harness, text) else {
            throw Refusal(message: "\(path.path) does not parse; it was left untouched")
        }
        let record = try readRecord()[harness] as? [String: Any]
        let ownedText = record.flatMap { $0["path"] as? String == path.path ? $0["text"] as? String : nil }
        var base = original
        var removed: String?
        if let ownedText, let range = uniqueRange(of: ownedText, in: text) {
            // Keys the user added under our table would attach to the previous one once it is gone.
            if harness == "codex", !Self.onlyBlankOrComments(text[range.upperBound...]) {
                throw Refusal(message: "\(path.path) has settings after the agencil entry that Agencil did not write; it was left untouched")
            }
            base = Data(text.replacingCharacters(in: range, with: "").utf8)
            removed = ownedText
        } else if declaresAgencil(harness, text) {
            throw Refusal(message: record == nil
                ? "\(path.path) already has an agencil entry that Agencil did not write; it was left untouched"
                : "the agencil entry in \(path.path) changed since Agencil wrote it; it was left untouched")
        }
        if uninstall {
            guard removed != nil else { print("agencil: nothing to remove in \(path.path)"); return 0 }
            return try apply(harness, path, current: original, existed: existed, result: base, inserted: nil, removed: removed,
                             dryRun: dryRun, deleteIfEmpty: record?["created"] as? Bool == true)
        }
        let insertion = try insert(harness, into: base, caller: caller)
        return try apply(harness, path, current: original, existed: existed, result: insertion.bytes, inserted: insertion.text,
                         removed: removed, dryRun: dryRun, deleteIfEmpty: false,
                         created: !existed || (record?["created"] as? Bool == true))
    }

    private func apply(_ harness: String, _ path: URL, current: Data, existed: Bool, result: Data, inserted: String?,
                       removed: String?, dryRun: Bool, deleteIfEmpty: Bool, created: Bool = false) throws -> Int32 {
        if dryRun {
            print("--- \(path.path)\n+++ \(path.path)")
            for line in (removed ?? "").split(separator: "\n") { print("-\(line)") }
            for line in (inserted ?? "").split(separator: "\n") { print("+\(line)") }
            return 0
        }
        // Installing records ownership before the file changes and removing forgets it after: a crash in between
        // leaves a record of text that is not in the file (harmless), never an entry in the file that nothing
        // admits to having written.
        let previous = try readRecord()
        var entries = previous
        if let inserted {
            entries[harness] = ["path": path.path, "text": inserted, "hash": Self.hash(inserted), "created": created]
            try writeRecord(entries)
        } else { entries.removeValue(forKey: harness) }
        do {
            try requireUnchanged(path, existed: existed, snapshot: current)
            if deleteIfEmpty && result.isEmpty {
                try FileManager.default.removeItem(at: path)
            } else {
                try Self.writeAtomically(result, to: path)
                let back = try Data(contentsOf: path)
                let verified = back == result && (inserted == nil || String(decoding: back, as: UTF8.self).contains(inserted!))
                    && parses(harness, String(decoding: back, as: UTF8.self))
                guard verified else {
                    // Restoring is safe only while the file is still what we wrote.
                    if back == result { try Self.writeAtomically(current, to: path) }
                    throw Refusal(message: "the written \(path.path) did not read back correctly; the original was restored")
                }
            }
        } catch {
            if inserted != nil { try? writeRecord(previous) }
            throw error
        }
        if inserted == nil { try writeRecord(entries) }
        print(inserted == nil ? "agencil: removed the agencil entry from \(path.path)" : "agencil: installed the agencil entry in \(path.path)")
        return 0
    }

    /// The file must still be the bytes we based the change on: a harness or an editor may have saved meanwhile.
    private func requireUnchanged(_ path: URL, existed: Bool, snapshot: Data) throws {
        let now = FileManager.default.fileExists(atPath: path.path) ? try? Data(contentsOf: path) : nil
        guard (existed ? now == snapshot : now == nil) else {
            throw Refusal(message: "\(path.path) changed while it was being edited; it was left as the other writer saved it")
        }
    }

    func parses(_ harness: String, _ text: String) -> Bool {
        if harness == "codex" { return TomlCheck.parses(text) }
        if text.allSatisfy({ $0.isWhitespace }) { return true }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any]
    }

    func declaresAgencil(_ harness: String, _ text: String) -> Bool {
        if harness == "codex" { return ConfigText.tomlDeclaresAgencil(text) }
        let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return (root?["mcp"] as? [String: Any])?["agencil"] != nil
    }

    private func insert(_ harness: String, into base: Data, caller: String) throws -> (bytes: Data, text: String) {
        let arguments = ["mcp", "--caller", caller]
        if harness == "codex" {
            let args = ([command] + arguments).dropFirst().map(ConfigText.jsonString).joined(separator: ", ")
            let separator = base.isEmpty ? "" : (base.last == 10 ? "\n" : "\n\n")
            let text = "\(separator)[mcp_servers.agencil]\ncommand = \(ConfigText.jsonString(command))\nargs = [\(args)]\n"
            return (base + Data(text.utf8), text)
        }
        let entry = "{\"type\": \"local\", \"command\": [\(([command] + arguments).map(ConfigText.jsonString).joined(separator: ", "))]}"
        let bytes = [UInt8](base)
        guard !bytes.allSatisfy({ [32, 9, 10, 13].contains($0) }) else {
            let text = "{\n  \"mcp\": {\n    \"agencil\": \(entry)\n  }\n}\n"
            return (Data(text.utf8), text)
        }
        guard let root = ConfigText.members(of: bytes, objectAt: 0) else { throw Refusal(message: "the config is not a JSON object") }
        let text: String, position: Int
        if let mcp = root.members.first(where: { $0.key == "mcp" }) {
            guard let inner = ConfigText.members(of: bytes, objectAt: mcp.value.lowerBound) else {
                throw Refusal(message: "\"mcp\" in the config is not an object")
            }
            let member = "\"agencil\": \(entry)"
            if let last = inner.members.last { text = ",\n    \(member)"; position = last.value.upperBound }
            else { text = "\n    \(member)\n  "; position = mcp.value.lowerBound + 1 }
        } else if let last = root.members.last {
            text = ",\n  \"mcp\": {\n    \"agencil\": \(entry)\n  }"; position = last.value.upperBound
        } else { text = "\n  \"mcp\": {\n    \"agencil\": \(entry)\n  }\n"; position = root.close }
        var result = bytes
        result.insert(contentsOf: Array(text.utf8), at: position)
        return (Data(result), text)
    }

    /// The text up to the next TOML table header holds nothing but blank lines and comments.
    private static func onlyBlankOrComments(_ rest: Substring) -> Bool {
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return true }
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") { return false }
        }
        return true
    }

    private func uniqueRange(of needle: String, in text: String) -> Range<String.Index>? {
        guard let first = text.range(of: needle), text.range(of: needle, range: first.upperBound..<text.endIndex) == nil else { return nil }
        return first
    }

    /// A symlink is followed only to a regular file this user owns; anything else is not ours to rewrite.
    private func writablePath(_ url: URL) throws -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        let target = (info.st_mode & S_IFMT) == S_IFLNK ? url.resolvingSymlinksInPath() : url
        guard stat(target.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw Refusal(message: "\(url.path) is not a regular file you own (or a link to one); it was left untouched")
        }
        return target
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        var mode: mode_t = 0o600
        var info = stat()
        if stat(url.path, &info) == 0 { mode = info.st_mode & 0o777 }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".agencil-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw Refusal(message: "cannot write beside \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { bytes -> Bool in
            var sent = 0
            while sent < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
        guard written, fchmod(descriptor, mode) == 0, fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw Refusal(message: "cannot replace \(url.path)")
        }
    }

    // MARK: claude (its own CLI writes its config; Agencil only reads it back to prove ownership)

    private var claudeConfig: URL {
        if let base = environment["AGENCIL_MCP_CONFIG_DIR"], !base.isEmpty {
            return URL(fileURLWithPath: base).appendingPathComponent("claude/claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// A hash of the user-scope `agencil` server as Claude's config holds it; nil when it holds none (or no config).
    /// The command of the user-scope `agencil` server in Claude's config; nil when there is none.
    private func claudeEntryCommand() -> String? {
        guard let data = try? Data(contentsOf: claudeConfig),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?["agencil"] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }
    private func claudeEntryHash() throws -> String? {
        guard FileManager.default.fileExists(atPath: claudeConfig.path) else { return nil }
        guard let data = try? Data(contentsOf: claudeConfig) else {
            throw Refusal(message: "\(claudeConfig.path) cannot be read; it was left untouched")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Refusal(message: "\(claudeConfig.path) does not parse; it was left untouched")
        }
        guard let entry = (root["mcpServers"] as? [String: Any])?["agencil"],
              let bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func runClaude(caller: String, dryRun: Bool, uninstall: Bool) throws -> Int32 {
        let arguments = uninstall ? ["mcp", "remove", "agencil", "--scope", "user"]
            : ["mcp", "add", "agencil", "--scope", "user", "--", command, "mcp", "--caller", caller]
        let line = (["claude"] + arguments).joined(separator: " ")
        let sandbox = ClaudeSandbox(environment: environment)
        if dryRun {
            print("+\(line)")
            if !uninstall { for addition in sandbox.missing() { print("+\(sandbox.url.path): \(addition.line)") } }
            return 0
        }
        var entries = try readRecord()
        let recorded = entries["claude"] as? [String: Any]
        let owned = (recorded?["sandbox"] as? [[String: String]] ?? []).compactMap { item in
            item["key"].flatMap { key in item["value"].flatMap { value in
                item["file"].map { ClaudeSandbox.Addition(key: key, value: value, file: $0) } } }
        }
        let present = try claudeEntryHash()
        let adopted = recorded?["adopted"] as? Bool == true
        // An entry Claude holds is ours only while it still hashes to what we saw right after writing it.
        // A "pending" record means a previous run died after asking claude to add the server: adopt what is there.
        let adopting = recorded?["pending"] as? Bool == true
        // An entry that already runs this very app is kept as it is, not refused: only the sandbox settings need repair.
        // It stays the owner's: Agencil never removes a server entry it did not write.
        let sameCommand = !uninstall && claudeEntryCommand() == command
        let ours = present != nil && present == recorded?["entry"] as? String
        if let present, !adopting, !adopted, !sameCommand, !ours {
            throw Refusal(message: recorded == nil
                ? "claude already has an agencil server that Agencil did not write; it was left untouched"
                : "the agencil server in claude changed since Agencil wrote it; it was left untouched")
        }
        if uninstall && recorded == nil { print("agencil: nothing to remove for claude"); return 0 }
        if present != nil, sameCommand {
            // Repeat run: the server entry is in place, so only the sandbox settings are repaired.
            if recorded == nil { entries["claude"] = ["command": line, "hash": Self.hash(line), "adopted": true] }
            try allowSandbox(&entries, sandbox, keeping: owned)
            print("agencil: the agencil server is already in claude")
            return 0
        }
        if uninstall && adopted {
            try sandbox.remove(owned)
            entries.removeValue(forKey: "claude")
            try writeRecord(entries)
            print("agencil: removed the agencil sandbox settings; the server entry in claude is yours and was left in place")
            return 0
        }
        let before = entries
        if !uninstall {
            entries["claude"] = ["command": line, "hash": Self.hash(line), "pending": true]
            try writeRecord(entries)
            // An entry an earlier version wrote with a command that does not start (a literal `~`) is replaced.
            if ours { _ = try runClaudeCLI(["mcp", "remove", "agencil", "--scope", "user"], before: before) }
        }
        try runClaudeCLI(arguments, line: line, before: before)
        if uninstall {
            try sandbox.remove(owned)
            entries.removeValue(forKey: "claude")
        } else {
            let entry = try claudeEntryHash()
            var written: [String: Any] = ["command": line, "hash": Self.hash(line)]
            if let entry { written["entry"] = entry }
            entries["claude"] = written
            try allowSandbox(&entries, sandbox, keeping: owned)
        }
        try writeRecord(entries)
        print(uninstall ? "agencil: removed the agencil server from claude" : "agencil: added the agencil server to claude")
        return 0
    }

    @discardableResult
    private func runClaudeCLI(_ arguments: [String], line: String? = nil, before: [String: Any]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { try? writeRecord(before); throw error }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? writeRecord(before)
            throw Refusal(message: "`\(line ?? (["claude"] + arguments).joined(separator: " "))` failed with status \(process.terminationStatus)")
        }
        return 0
    }

    /// Records what is about to be added before the settings change, so a crash in between cannot lose ownership.
    private func allowSandbox(_ entries: inout [String: Any], _ sandbox: ClaudeSandbox, keeping owned: [ClaudeSandbox.Addition]) throws {
        let planned = sandbox.missing()
        try recordSandbox(&entries, adding: planned, keeping: owned)
        _ = try sandbox.apply(planned)
    }

    /// Records the sandbox values Agencil added (and keeps the ones an earlier run added) in the claude entry.
    private func recordSandbox(_ entries: inout [String: Any], adding added: [ClaudeSandbox.Addition],
                               keeping owned: [ClaudeSandbox.Addition]) throws {
        var claude = entries["claude"] as? [String: Any] ?? [:]
        let all = owned + added.filter { !owned.contains($0) }
        if all.isEmpty { claude.removeValue(forKey: "sandbox") } else { claude["sandbox"] = all.map(\.record) }
        entries["claude"] = claude
        try writeRecord(entries)
    }

    /// Whether the claude entry is installed, the sandbox is enabled and its settings still lack a value.
    var claudeSandboxBlocks: Bool { !ClaudeSandbox(environment: environment).missing().isEmpty }

    // MARK: installed.json

    private func readRecord() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: recordURL) else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Refusal(message: "installed.json does not parse; fix or remove it first")
        }
        return root["entries"] as? [String: Any] ?? [:]
    }

    private func writeRecord(_ entries: [String: Any]) throws {
        try Self.writeAtomically(UnixSocket.json(["entries": entries]), to: recordURL)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
