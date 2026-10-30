import Darwin
import Foundation

public struct ConfigSnapshot: Sendable, Equatable {
    public let revision: Int64
    public let values: [String: String]
}

/// `config.json` in the Agencil home: every setting, saved as it changes. One exclusive `flock` covers a
/// read-modify-write, the file is replaced atomically, and a write based on an older revision is refused.
/// Writers cooperate through config.lock; a process of the same user that deliberately replaces the lock or
/// the file is outside what this guards (docs: a same-user process is not a boundary), but it is detected
/// and refused wherever the file system lets us see it.
public struct ConfigStore {
    public enum Failure: Error, Equatable, LocalizedError {
        case staleRevision
        case malformed
        case unsafeFile(String)
        case durabilityUnconfirmed

        public var errorDescription: String? {
            switch self {
            case .staleRevision: "config.json changed since it was read; read it again and retry"
            case .malformed: "config.json is not valid: fix or remove it, nothing was written"
            case .unsafeFile(let reason): "config.json is refused: \(reason)"
            case .durabilityUnconfirmed: "config.json was replaced but could not be flushed to disk; read it again before retrying"
            }
        }
    }

    private struct Document: Codable {
        var revision: Int64
        var values: [String: String]
    }

    private let directory: URL
    private let beforeRename: (@Sendable () throws -> Void)?

    /// `beforeRename` runs after the temporary file is flushed and before it replaces the config: the
    /// fault-injection point for a crash in between.
    public init(directory: URL, beforeRename: (@Sendable () throws -> Void)? = nil) {
        self.directory = directory
        self.beforeRename = beforeRename
    }

    private var file: URL { directory.appendingPathComponent("config.json") }
    private var lockFile: URL { directory.appendingPathComponent("config.lock") }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    public func read() throws -> ConfigSnapshot {
        let (document, _) = try load()
        return ConfigSnapshot(revision: document.revision, values: document.values)
    }

    /// `expectedRevision` nil is a locked read-modify-write on whatever is current; a stale explicit revision
    /// throws before `change` runs.
    @discardableResult
    public func update(expectedRevision: Int64? = nil, _ change: (inout [String: String]) -> Void) throws -> ConfigSnapshot {
        let lock = try acquireLock()
        defer { close(lock) }
        var (document, identity) = try load()
        if let expectedRevision, expectedRevision != document.revision { throw Failure.staleRevision }
        change(&document.values)
        let (next, overflow) = document.revision.addingReportingOverflow(1)
        guard !overflow else { throw Failure.malformed }
        document.revision = next
        try write(document, replacing: identity)
        return ConfigSnapshot(revision: document.revision, values: document.values)
    }

    /// The lock must be a regular file of ours, and still the file at its path once held: a lock that was
    /// replaced while we waited guards nothing, so the open is repeated on the new file.
    private func acquireLock() throws -> Int32 {
        for _ in 0..<5 {
            let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.unsafeFile("cannot open config.lock (\(String(cString: strerror(errno))))") }
            var held = stat()
            guard fstat(descriptor, &held) == 0, (held.st_mode & S_IFMT) == S_IFREG,
                  held.st_uid == getuid(), held.st_mode & 0o022 == 0 else {
                close(descriptor)
                throw Failure.unsafeFile("config.lock is not a private regular file of this user")
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                close(descriptor)
                throw Failure.unsafeFile("cannot lock config.lock")
            }
            var current = stat()
            if lstat(lockFile.path, &current) == 0, current.st_ino == held.st_ino, current.st_dev == held.st_dev {
                return descriptor
            }
            close(descriptor)
        }
        throw Failure.unsafeFile("config.lock keeps being replaced")
    }

    /// A missing file is revision 0 with no values. A symlink, another owner's file or a syntax error fails.
    private func load() throws -> (Document, FileIdentity?) {
        // The checks are made on the opened descriptor, so the file cannot be swapped between check and read.
        // Non-blocking, so a FIFO planted at the path fails the type check instead of hanging the open.
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return (Document(revision: 0, values: [:]), nil) }
            throw Failure.unsafeFile(errno == ELOOP ? "it is a symbolic link" : "cannot open it")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafeFile("it is not a regular file") }
        guard info.st_uid == getuid() else { throw Failure.unsafeFile("it belongs to another user") }
        guard let data = try? handle.readToEnd(),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.revision >= 0, document.revision < Int64.max else { throw Failure.malformed }
        return (document, FileIdentity(device: info.st_dev, inode: info.st_ino))
    }

    private func write(_ document: Document, replacing identity: FileIdentity?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let temporary = directory.appendingPathComponent("config.json.tmp-\(getpid())-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unsafeFile("cannot create a temporary file") }
        var committed = false
        defer { if !committed { unlink(temporary.path) } }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let flushed = written == data.count && fsync(descriptor) == 0
        close(descriptor)
        guard flushed else { throw Failure.unsafeFile("cannot write the temporary file") }
        try beforeRename?()
        // The destination must still be the very file that was loaded (or still absent): it may have been
        // swapped since load().
        var existing = stat()
        if lstat(file.path, &existing) == 0 {
            guard let identity, existing.st_dev == identity.device, existing.st_ino == identity.inode else {
                throw Failure.unsafeFile("it changed while it was being written")
            }
        } else if errno != ENOENT || identity != nil {
            throw Failure.unsafeFile("it changed while it was being written")
        }
        guard rename(temporary.path, file.path) == 0 else { throw Failure.unsafeFile("cannot replace it") }
        committed = true
        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw Failure.durabilityUnconfirmed }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw Failure.durabilityUnconfirmed }
    }
}
