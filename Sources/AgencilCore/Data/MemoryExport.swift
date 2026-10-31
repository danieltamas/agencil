import Darwin
import Foundation

public struct MemoryTarget: Equatable, Sendable {
    public let repo: String
    public let folder: String
    public let enabled: Bool

    public init(repo: String, folder: String, enabled: Bool) {
        self.repo = repo
        self.folder = folder
        self.enabled = enabled
    }
}

public struct ExportReport: Equatable, Sendable {
    public let written: Int
    public let unchanged: Int
    public let skipped: Int
}

/// Writes each finished sitting of a repo that is turned on as one Markdown file in that repo's memory folder.
public final class MemoryExport: @unchecked Sendable {
    private static let key = "memory_export"

    let ledger: Ledger
    private let store: ConfigStore

    public init(ledger: Ledger, directory: URL) {
        self.ledger = ledger
        store = ConfigStore(directory: directory)
    }

    public static func fileName(number: Int) -> String { "agencil-sitting-\(String(format: "%04d", number)).md" }

    // MARK: Targets

    public func targets() throws -> [MemoryTarget] {
        guard let text = try store.read().values[Self.key] else { return [] }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else {
            throw DataError(message: "\(Self.key) is not a list of objects")
        }
        let targets = try list.map { item -> MemoryTarget in
            guard let repo = item["repo"] as? String, let folder = item["folder"] as? String, let enabled = SeatConfig.flag(item["enabled"]) else {
                throw DataError(message: "\(Self.key) entries need repo, folder and enabled")
            }
            return MemoryTarget(repo: repo, folder: folder, enabled: enabled)
        }
        try Self.validate(targets)
        return targets
    }

    public func save(_ targets: [MemoryTarget]) throws {
        try Self.validate(targets)
        let list = targets.map { ["repo": $0.repo, "folder": $0.folder, "enabled": $0.enabled] as [String: Any] }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        _ = try store.update { $0[Self.key] = text }
    }

    static func validate(_ targets: [MemoryTarget]) throws {
        var repos = Set<String>()
        for target in targets {
            for path in [target.repo, target.folder] {
                guard path.hasPrefix("/"), path.count > 1, !path.contains("\0"), !path.split(separator: "/").contains("..") else {
                    throw DataError(message: "\(path) is not an absolute path without ..")
                }
            }
            guard repos.insert(target.repo).inserted else { throw DataError(message: "repo \(target.repo) is listed twice") }
        }
    }

    // MARK: Running

    private struct Sitting {
        let id: String
        let number: Int
        let running: Bool
    }

    public func run(now: Date) throws -> ExportReport {
        let targets = try targets().filter(\.enabled)
        guard !targets.isEmpty else { return ExportReport(written: 0, unchanged: 0, skipped: 0) }
        let states = try ledger.locked { try OutcomeBook(ledger: ledger).loadClaims(now: now) }.reduce(into: [String: String]()) { $0[$1.id] = "\($1.status)" }
        var written = 0, unchanged = 0, skipped = 0
        for target in targets {
            let sittings = try ledger.locked {
                try ledger.query("SELECT id, no, state FROM sittings WHERE repo = ? ORDER BY no;", [target.repo]) {
                    Sitting(id: Ledger.text($0, 0) ?? "", number: Int(Ledger.text($0, 1) ?? "") ?? 0, running: Ledger.text($0, 2) == "running")
                }
            }
            for sitting in sittings {
                if sitting.running { skipped += 1; continue }
                let markdown = try render(sitting.id, number: sitting.number, statuses: states)
                if try Self.publish(markdown, name: Self.fileName(number: sitting.number), in: target.folder) { written += 1 } else { unchanged += 1 }
            }
        }
        return ExportReport(written: written, unchanged: unchanged, skipped: skipped)
    }

    /// Writes `text` unless the file already holds exactly it, and reports whether it wrote. Every step is relative to the
    /// folder opened once (so a link swapped in afterwards changes nothing), the content goes to a temporary name that is
    /// renamed over the file (a symlink at the file is replaced, never followed), and a failure keeps the old file whole.
    private static func publish(_ text: String, name: String, in folder: String) throws -> Bool {
        let directory = try openFolder(folder)
        defer { close(directory) }
        let data = Data(text.utf8)
        let existing = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        if existing >= 0 {
            defer { close(existing) }
            var info = stat()
            if fstat(existing, &info) == 0, info.st_mode & S_IFMT == S_IFREG, FileHandle(fileDescriptor: existing, closeOnDealloc: false).readDataToEndOfFile() == data {
                return false
            }
        }
        let temporary = "." + name + "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RunsTree.failure("could not write in \(folder)") }
        let complete = data.withUnsafeBytes { buffer in
            buffer.isEmpty || write(descriptor, buffer.baseAddress, buffer.count) == buffer.count
        } && fsync(descriptor) == 0
        close(descriptor)
        guard complete, renameat(directory, temporary, directory, name) == 0 else {
            unlinkat(directory, temporary, 0)
            throw RunsTree.failure("could not write \(name)")
        }
        return true
    }

    /// The memory folder, created when missing. It must be ours alone to write: a folder another user (or group) can write
    /// to would let them swap the file between the check and the rename.
    private static func openFolder(_ folder: String) throws -> Int32 {
        var descriptor = open(folder, O_RDONLY | O_DIRECTORY)
        if descriptor < 0, errno == ENOENT {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            descriptor = open(folder, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else { throw RunsTree.failure("cannot open \(folder)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(descriptor)
            throw DataError(message: "\(folder) must be owned by you and not writable by others")
        }
        return descriptor
    }
}
