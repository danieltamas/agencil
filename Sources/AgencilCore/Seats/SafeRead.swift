import Foundation

/// Reads of files a seat could have replaced, done by the unconfined broker (docs/U40-SPEC.md). A link is never
/// followed and a FIFO or device is never opened for reading, so a seat cannot turn its answer file into a pointer at
/// an owner secret or a hang. The read itself is bounded, since a regular file can grow after it was judged.
enum SafeRead {
    /// Seat output: an answer or a JSON event stream.
    static let outputLimit = 16 << 20

    /// The file's bytes when `path` is a regular file of at most `limit` bytes; nil otherwise. Its folder is opened
    /// without following a link too: the seat may write its run directory's own entry, so it could swap the whole
    /// folder for a link.
    static func file(_ path: String, limit: Int = outputLimit) -> Data? {
        bounded(leaf(path), limit: limit)
    }

    static func text(_ path: String, limit: Int = outputLimit) -> String? {
        file(path, limit: limit).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// An owner file at `relative` under `home`: every folder on the way is opened without following a link, so a
    /// linked folder (`~/.local/share/opencode` -> `~/.codex`) cannot route the read to another credential.
    static func ownerFile(home: String, relative: String, limit: Int) -> Data? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let leaf = parts.last, !parts.contains(".."), !parts.contains(".") else { return nil }
        var folder = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        for part in parts.dropLast() {
            guard folder >= 0 else { return nil }
            let next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(folder)
            folder = next
        }
        guard folder >= 0 else { return nil }
        defer { close(folder) }
        return bounded(openat(folder, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), limit: limit)
    }

    /// The last `count` bytes of a regular file (a log the seat writes into), however large it grew.
    static func tail(_ path: String, count: Int) -> Data? {
        let descriptor = leaf(path)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        guard (try? handle.seek(toOffset: UInt64(max(0, Int(status.st_size) - count)))) != nil else { return nil }
        return try? handle.read(upToCount: count) ?? Data()
    }

    /// `path` opened for reading with neither it nor its folder followed as a link; -1 when that fails.
    private static func leaf(_ path: String) -> Int32 {
        let url = URL(fileURLWithPath: path)
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return -1 }
        defer { close(folder) }
        return openat(folder, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }

    /// At most `limit` bytes from a regular file; more than that, or anything that is not a regular file, is nil.
    private static func bounded(_ descriptor: Int32, limit: Int) -> Data? {
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= limit else { return nil }
        var data = Data()
        while data.count <= limit {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: min(1 << 20, limit + 1 - data.count)) } catch { return nil }
            // nil is the end of the file.
            guard let chunk, !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        return nil
    }
}
