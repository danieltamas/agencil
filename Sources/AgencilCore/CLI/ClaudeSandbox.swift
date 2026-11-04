import Foundation

/// Claude Code's sandbox (`~/.claude/settings.json`, docs/U26-SPEC.md, narrowed by docs/U32-SPEC.md): a sandboxed session
/// may not reach a socket unless the settings allow it, so installing the Claude entry allows the agent door and nothing
/// else: never the owner door, never a write to the state directory. Only an enabled sandbox in a parsable file is
/// touched, only a value whose array is a plain list of strings is edited, and every other key is left as it was.
struct ClaudeSandbox {
    struct Addition: Equatable {
        let key: String
        let value: String
        /// The settings file the value went into: ownership never carries over to another file.
        let file: String

        var record: [String: String] { ["key": key, "value": value, "file": file] }
        var path: [String] { key.split(separator: ".").map(String.init) }
        var line: String { "\(key) += \(value)" }
    }

    let url: URL

    init(environment: [String: String]) {
        if let base = environment["AGENCIL_MCP_CONFIG_DIR"], !base.isEmpty {
            url = URL(fileURLWithPath: base).appendingPathComponent("claude/settings.json")
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        }
    }

    private var wanted: [Addition] {
        [Addition(key: "sandbox.network.allowUnixSockets", value: "~/.agencil/agent.sock", file: url.path)]
    }

    /// What v0.4.1 and earlier added: the whole state directory for writing and the owner door. Agencil removes the ones
    /// it recorded; a value the owner had before is never recorded, so never removed.
    static func isLegacy(_ addition: Addition) -> Bool {
        (addition.key == "sandbox.filesystem.allowWrite" && addition.value == "~/.agencil")
            || (addition.key == "sandbox.network.allowUnixSockets" && addition.value == "~/.agencil/agencil.sock")
    }

    /// The settings bytes and parsed object when the sandbox is enabled; nil for a missing or unparsable file or a
    /// sandbox that is off.
    private func enabledSettings() -> (data: Data, root: [String: Any])? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.isTrue((root["sandbox"] as? [String: Any])?["enabled"]) else { return nil }
        return (data, root)
    }

    /// Only the JSON boolean true counts: NSNumber also bridges 1 to Bool.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }

    /// What the settings still lack and can take; empty when the sandbox is off, absent or already allows both.
    func missing() -> [Addition] {
        guard let settings = enabledSettings() else { return [] }
        return wanted.filter { addition in
            guard let list = Self.list(in: settings.root, at: addition.path) else { return false }
            return !list.contains(addition.value)
        }
    }

    /// Adds what is missing, atomically with the file's mode kept, and returns what was added. A write is refused when
    /// the file changed since it was read.
    func apply(_ planned: [Addition]) throws -> [Addition] {
        guard var settings = enabledSettings() else { return [] }
        let added = planned.filter { missing().contains($0) }
        guard !added.isEmpty else { return [] }
        for addition in added {
            settings.root = Self.setting(settings.root, path: addition.path[...]) { $0 + [addition.value] }
        }
        try write(settings.root, replacing: settings.data)
        return added
    }

    /// Removes the recorded values from this file and returns the ones that are confirmed gone: removed now, or already
    /// absent from a readable list. A value in a file that cannot be read, or whose list is not plain strings, is not
    /// confirmed, so the caller keeps its record. Works on a settings file whose sandbox is switched off too: the values
    /// must not come back when it is switched on again.
    func removeConfirmed(_ recorded: [Addition]) throws -> [Addition] {
        let own = recorded.filter { $0.file == url.path }
        guard !own.isEmpty, let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var confirmed: [Addition] = [], changed = false
        for addition in own {
            guard let list = Self.list(in: root, at: addition.path) else { continue }
            if list.contains(addition.value) {
                root = Self.setting(root, path: addition.path[...]) { $0.filter { $0 != addition.value } }
                changed = true
            }
            confirmed.append(addition)
        }
        if changed { try write(root, replacing: data) }
        return confirmed
    }

    /// Writes through a symlink to its target, and only when the file still holds the bytes that were read.
    private func write(_ root: [String: Any], replacing original: Data) throws {
        let target = url.resolvingSymlinksInPath()
        guard (try? Data(contentsOf: target)) == original else {
            throw McpInstaller.Refusal(message: "\(url.path) changed while Agencil was editing it; it was left untouched")
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try McpInstaller.writeAtomically(data + Data("\n".utf8), to: target)
    }

    /// The string list at `path`: an absent list is empty, a list with anything but strings (or a non-object on the
    /// way) is nil, which leaves it alone.
    private static func list(in root: [String: Any], at path: [String]) -> [String]? {
        var node: Any? = root
        for key in path.dropLast() {
            guard let next = (node as? [String: Any])?[key] else { return [] }
            guard next is [String: Any] else { return nil }
            node = next
        }
        guard let last = path.last, let leaf = (node as? [String: Any])?[last] else { return [] }
        return leaf as? [String]
    }

    private static func setting(_ node: [String: Any], path: ArraySlice<String>, _ change: ([String]) -> [String]) -> [String: Any] {
        guard let key = path.first else { return node }
        var copy = node
        copy[key] = path.count == 1
            ? change(node[key] as? [String] ?? [])
            : setting(node[key] as? [String: Any] ?? [:], path: path.dropFirst(), change)
        return copy
    }
}
