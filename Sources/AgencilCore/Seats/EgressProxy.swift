import Darwin
import Foundation

/// A loopback HTTP proxy that opens `CONNECT` tunnels to a fixed set of hosts on one port and refuses everything else
/// (docs/U38-SPEC.md). Any local process can reach it, so it must never be useful beyond those hosts: the host is
/// matched as text before any lookup, and there is no plain-HTTP forwarding.
final class EgressProxy: @unchecked Sendable {
    struct Failure: Error { let message: String }

    let port: Int
    private let allowedHosts: Set<String>
    private let allowedPort: Int
    /// One per loopback address, IPv4 and IPv6, on the same port: a seat's profile can only say `localhost:<port>`,
    /// which covers both, so both are held or another local user could listen on the one left free.
    private let listeners: [Int32]
    private let lock = NSLock()
    private var stopped = false
    private var lookups = 0
    /// Every socket a connection thread owns, from accept on. They are closed under the lock, after leaving this set,
    /// so `stop` never shuts down a descriptor number that has since been reused.
    private var held: Set<Int32> = []

    /// Sockets held at once, two per open tunnel; a new connection past it is closed unanswered.
    private static let descriptorLimit = 256
    private static let headLimit = 8192
    private static let headSeconds = 10.0
    private static let connectSeconds = 15.0
    /// Name lookups in flight at once. A lookup cannot be cancelled, so one that stalls keeps its place until the
    /// resolver gives up; past the limit a tunnel is refused instead of starting another.
    private static let lookupLimit = 16
    /// A peer that stops reading ends its tunnel instead of holding a connection thread for ever.
    private static let sendSeconds = 30
    /// Longer than any wait for a model's next byte; a tunnel silent both ways for this long is abandoned.
    private static let idleMilliseconds: Int32 = 900_000

    init(allowedHosts: Set<String>, allowedPort: Int = 443) throws {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowedPort = allowedPort
        // The system picks the IPv4 port; the same number must then be free on IPv6, or another pair is tried.
        var pair: (v4: Int32, v6: Int32, port: UInt16)?
        for _ in 0..<16 where pair == nil {
            guard let v4 = Self.loopbackListener(family: AF_INET, port: 0) else { continue }
            if let v6 = Self.loopbackListener(family: AF_INET6, port: v4.port) {
                pair = (v4.descriptor, v6.descriptor, v4.port)
            } else {
                close(v4.descriptor)
            }
        }
        guard let pair else { throw Failure(message: "cannot listen on both loopback addresses") }
        listeners = [pair.v4, pair.v6]
        port = Int(pair.port)
        for listener in listeners { Thread.detachNewThread { [self] in acceptLoop(listener) } }
    }

    /// A non-blocking listener on the loopback address of `family`, on `port` (0: any), and the port it got.
    private static func loopbackListener(family: Int32, port: UInt16) -> (descriptor: Int32, port: UInt16)? {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var storage = sockaddr_storage()
        var size: socklen_t
        if family == AF_INET6 {
            var only: Int32 = 1
            setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            size = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                    address.pointee.sin6_len = UInt8(size)
                    address.pointee.sin6_family = sa_family_t(AF_INET6)
                    address.pointee.sin6_port = port.bigEndian
                    address.pointee.sin6_addr = in6addr_loopback
                }
            }
        } else {
            size = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                    address.pointee.sin_len = UInt8(size)
                    address.pointee.sin_family = sa_family_t(AF_INET)
                    address.pointee.sin_port = port.bigEndian
                    address.pointee.sin_addr.s_addr = inet_addr("127.0.0.1")
                }
            }
        }
        let ready = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, size) == 0 && getsockname(descriptor, $0, &size) == 0 && listen(descriptor, 64) == 0
            }
        }
        guard ready else { close(descriptor); return nil }
        // The port sits at the same place in both address shapes.
        let bound = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port } }
        return (descriptor, UInt16(bigEndian: bound))
    }

    /// Closes the listeners and ends every connection, whatever phase it is in. The listeners are closed under the
    /// lock the accept loops take, so a loop never accepts on a descriptor number that has since been reused.
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            for listener in listeners { close(listener) }
            for descriptor in held { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            _ = poll(&waiting, 1, 200)
            var outOfDescriptors = false
            let accepted: Int32? = lock.withLock {
                if stopped { return nil }
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    outOfDescriptors = errno == EMFILE || errno == ENFILE
                    return -1
                }
                guard held.count < Self.descriptorLimit else { close(client); return -1 }
                held.insert(client)
                return client
            }
            guard let client = accepted else { return }
            // A queued connection that cannot be accepted keeps the listener readable: wait instead of spinning.
            if outOfDescriptors { usleep(100_000) }
            guard client >= 0 else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    /// Takes a socket a connection thread just opened; false, with the socket closed, once the proxy has stopped.
    private func hold(_ descriptor: Int32) -> Bool {
        lock.withLock {
            if stopped { close(descriptor); return false }
            held.insert(descriptor)
            return true
        }
    }

    private func release(_ descriptor: Int32) {
        lock.withLock {
            held.remove(descriptor)
            close(descriptor)
        }
    }

    private func serve(_ client: Int32) {
        defer { release(client) }
        Self.prepare(client)
        guard let request = readHead(client) else { return }
        let words = request.firstLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count == 3, words[0] == "CONNECT" else {
            Self.send(client, Data("HTTP/1.1 405 Method Not Allowed\r\n\r\n".utf8))
            return
        }
        guard let target = allowedTarget(words[1]) else {
            Self.send(client, Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
            return
        }
        guard let upstream = connect(host: target) else {
            Self.send(client, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            return
        }
        defer { release(upstream) }
        guard Self.send(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)),
              request.early.isEmpty || Self.send(upstream, request.early) else { return }
        Self.relay(client, upstream)
    }

    /// The allowed host a `CONNECT` target names, or nil. Compared as text: an address literal, a trailing dot or a
    /// longer name is simply not in the list, and nothing is resolved for a target that is refused.
    private func allowedTarget(_ target: String) -> String? {
        guard let colon = target.lastIndex(of: ":"), String(target[target.index(after: colon)...]) == String(allowedPort) else { return nil }
        let host = target[..<colon].lowercased()
        return allowedHosts.contains(host) ? host : nil
    }

    /// The request line, and any bytes the client sent after the blank line. Nil when the head, blank line included,
    /// is longer than the limit or does not end in time.
    private func readHead(_ client: Int32) -> (firstLine: String, early: Data)? {
        let deadline = Date().addingTimeInterval(Self.headSeconds)
        let terminator = Data("\r\n\r\n".utf8)
        var head = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = head.range(of: terminator) {
                guard end.upperBound - head.startIndex <= Self.headLimit else { return nil }
                let firstLine = head[..<end.lowerBound].split(separator: 13, maxSplits: 1).first.map { String(decoding: $0, as: UTF8.self) }
                return firstLine.map { ($0, Data(head[end.upperBound...])) }
            }
            let remaining = deadline.timeIntervalSinceNow
            guard head.count <= Self.headLimit, remaining > 0 else { return nil }
            var waiting = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, Int32(remaining * 1000) + 1) > 0 else { continue }
            let count = recv(client, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            head.append(contentsOf: chunk[0..<count])
        }
    }

    /// A name lookup that may outlast its caller: `getaddrinfo` cannot be cancelled, so it runs on a thread of its own
    /// and whoever is last (the caller on time, or the lookup after the caller gave up) frees the addresses.
    private final class Lookup: @unchecked Sendable {
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        var addresses: UnsafeMutablePointer<addrinfo>?
        var abandoned = false
    }

    private func resolve(_ host: String, until deadline: Date) -> UnsafeMutablePointer<addrinfo>? {
        let admitted = lock.withLock { () -> Bool in
            guard lookups < Self.lookupLimit else { return false }
            lookups += 1
            return true
        }
        guard admitted else { return nil }
        let lookup = Lookup()
        let service = String(allowedPort)
        Thread.detachNewThread { [self] in
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var found: UnsafeMutablePointer<addrinfo>?
            let failed = getaddrinfo(host, service, &hints, &found) != 0
            lookup.lock.withLock {
                if lookup.abandoned || failed { if let found { freeaddrinfo(found) } } else { lookup.addresses = found }
            }
            lock.withLock { lookups -= 1 }
            lookup.finished.signal()
        }
        _ = lookup.finished.wait(timeout: .now() + max(deadline.timeIntervalSinceNow, 0))
        return lookup.lock.withLock {
            lookup.abandoned = true
            defer { lookup.addresses = nil }
            return lookup.addresses
        }
    }

    /// A held, connected socket to the first address of `host` that answers; lookup and connects share one deadline,
    /// and a proxy stopped meanwhile connects to nothing.
    private func connect(host: String) -> Int32? {
        let deadline = Date().addingTimeInterval(Self.connectSeconds)
        guard let first = resolve(host, until: deadline) else { return nil }
        defer { freeaddrinfo(first) }
        for candidate in sequence(first: first, next: { $0.pointee.ai_next }) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let descriptor = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            guard descriptor >= 0 else { continue }
            guard hold(descriptor) else { return nil }
            Self.prepare(descriptor)
            let flags = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            var connected = Darwin.connect(descriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0
            if !connected && errno == EINPROGRESS {
                var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                connected = poll(&waiting, 1, Int32(remaining * 1000) + 1) > 0
                    && getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == 0
            }
            if connected {
                _ = fcntl(descriptor, F_SETFL, flags)
                return descriptor
            }
            release(descriptor)
        }
        return nil
    }

    /// Blocking, no SIGPIPE, not inherited by a seat, and a send that gives up on a peer that stopped reading.
    private static func prepare(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        var noPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var patience = timeval(tv_sec: sendSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Copies bytes both ways until either side closes, fails, stops reading, or both stay silent too long.
    private static func relay(_ first: Int32, _ second: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var ends = [pollfd(fd: first, events: Int16(POLLIN), revents: 0), pollfd(fd: second, events: Int16(POLLIN), revents: 0)]
        while true {
            let ready = poll(&ends, 2, idleMilliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return }
            for (index, end) in ends.enumerated() where end.revents != 0 {
                let count = recv(end.fd, &chunk, chunk.count, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, send(ends[1 - index].fd, Data(chunk[0..<count])) else { return }
            }
        }
    }

    /// False when the peer closed, failed, or took no bytes for `sendSeconds`.
    @discardableResult
    private static func send(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}
