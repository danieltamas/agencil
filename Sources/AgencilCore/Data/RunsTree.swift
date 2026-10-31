import Darwin
import Foundation

/// A directory walked by file descriptor: every step is relative to a directory that is already open and never follows
/// a symlink, so a link swapped in while the walk runs cannot send it somewhere else.
enum RunsTree {
    struct Entry {
        let name: String
        let mode: mode_t
        let size: Int64
        let modified: Date

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isFile: Bool { mode & S_IFMT == S_IFREG }
    }

    static func failure(_ what: String) -> DataError { DataError(message: "\(what): \(String(cString: strerror(errno)))") }

    /// The directory at `path` opened without following a symlink at its end; nil when it does not exist.
    static func open(_ path: String) throws -> Int32? {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if descriptor >= 0 { return descriptor }
        if errno == ENOENT { return nil }
        throw failure("cannot open \(path)")
    }

    /// The child directory `name` of `parent`; nil when it was replaced by something that is not a plain directory.
    static func openChild(_ parent: Int32, _ name: String) throws -> Int32? {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if descriptor >= 0 { return descriptor }
        if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return nil }
        throw failure("cannot open \(name)")
    }

    static func entries(of directory: Int32) throws -> [Entry] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else { throw failure("cannot read a directory") }
        defer { closedir(stream) }
        var names: [String] = []
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return try names.sorted().compactMap { name in
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw failure("cannot inspect \(name)")
            }
            let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            return Entry(name: name, mode: info.st_mode, size: Int64(info.st_size), modified: Date(timeIntervalSince1970: seconds))
        }
    }

    /// Total size of the regular files below `directory`.
    static func size(of directory: Int32) throws -> Int64 {
        var total: Int64 = 0
        for entry in try entries(of: directory) {
            if entry.isFile { total += entry.size }
            else if entry.isDirectory, let child = try openChild(directory, entry.name) {
                defer { close(child) }
                total += try size(of: child)
            }
        }
        return total
    }

    /// Deletes the regular files of `entries` (and of the directories below) last modified before `cutoff`, and removes
    /// the directories that deleting emptied. Names in `protected` are left alone. Returns whether anything was
    /// deleted and whether anything is left.
    static func prune(_ directory: Int32, entries: [Entry], protected: Set<String> = [], before cutoff: Date,
                      deleted: (Int64) -> Void) throws -> (removed: Bool, remains: Bool) {
        var removed = false
        var remains = false
        for entry in entries {
            if protected.contains(entry.name) { remains = true; continue }
            if entry.isDirectory {
                guard let child = try openChild(directory, entry.name) else { remains = true; continue }
                let inner: (removed: Bool, remains: Bool)
                do {
                    defer { close(child) }
                    inner = try prune(child, entries: try Self.entries(of: child), before: cutoff, deleted: deleted)
                }
                removed = removed || inner.removed
                if inner.removed, !inner.remains, unlinkat(directory, entry.name, AT_REMOVEDIR) == 0 { continue }
                remains = true
            } else if entry.isFile, entry.modified < cutoff {
                guard unlinkat(directory, entry.name, 0) == 0 else { throw failure("could not delete \(entry.name)") }
                deleted(entry.size)
                removed = true
            } else {
                remains = true
            }
        }
        return (removed, remains)
    }
}
