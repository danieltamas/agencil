import Darwin
import Foundation

/// The JSON-lines transport of the broker socket: one object per line in each direction.
public enum UnixSocket {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// One request line is capped; a longer line is a protocol fault, never memory growth.
    public static let lineLimit = 1_048_576

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure(message: "socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Binds and listens with the socket created 0600: the umask is tightened around bind so no wider mode exists.
    public static func listen(at path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindError = errno
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 64) == 0 else {
            close(descriptor)
            throw Failure(message: "cannot listen on \(path): \(String(cString: strerror(bound == 0 ? errno : bindError)))")
        }
        return descriptor
    }

    /// Nil when nothing answers at `path` (no socket, or a stale one nobody listens on).
    public static func connect(to path: String) throws -> Int32? {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            if errno == ENOENT || errno == ECONNREFUSED { return nil }
            throw Failure(message: "cannot connect to \(path): \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    /// The pid at the other end of a connected socket, or nil when the kernel will not say.
    public static func peerPID(_ descriptor: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Buffered line reader. A line over `lineLimit` is skipped to its newline and reported as `.tooLong`.
    public final class Reader {
        public enum Line { case line(Data), tooLong, end }
        private let descriptor: Int32
        private var buffer = Data()
        private var discarding = false

        public init(descriptor: Int32) { self.descriptor = descriptor }

        public func next() -> Line {
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if discarding || line.count > lineLimit { discarding = false; return .tooLong }
                    return .line(Data(line))
                }
                if buffer.count > lineLimit { buffer.removeAll(); discarding = true }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let count = read(descriptor, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return .end }
                if discarding {
                    if let newline = chunk.prefix(count).firstIndex(of: 10) {
                        buffer.append(contentsOf: chunk[newline..<count])
                    }
                } else { buffer.append(contentsOf: chunk[0..<count]) }
            }
        }
    }

    @discardableResult
    public static func write(_ descriptor: Int32, line: Data) -> Bool {
        var data = line
        data.append(10)
        return data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    public static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
