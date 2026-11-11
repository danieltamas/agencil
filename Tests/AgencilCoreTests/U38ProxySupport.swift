@testable import AgencilCore
import Darwin
import Foundation
import Testing
enum U38ProxySocket {
    static func profile(_ root: URL, port: Int) -> String {
        Confinement.profile(copy: root.appendingPathComponent("run/copy").path,
            runDirectory: root.appendingPathComponent("run").path, executable: "/usr/bin/python3",
            harness: "codex", home: U34Support.testHome(root),
            brokerHome: root.appendingPathComponent("broker").path, egressPort: port)
    }

    static func recordEnvironment(_ rig: U6dRig, harness: String) throws {
        let stub = rig.base.bin.appendingPathComponent(harness)
        let script = try String(contentsOf: stub, encoding: .utf8)
        let anchor = "printf '%s\\n' \"$PWD\" > \"$record.cwd\""
        try #require(script.contains(anchor))
        try script.replacingOccurrences(of: anchor, with:
            anchor + "\nprintf '%s\\n' \"${HTTPS_PROXY-unset}\" > \"$record.proxy\"")
            .write(to: stub, atomically: false, encoding: .utf8)
    }

    static func observedRun(_ rig: U6dRig, excluding: Set<String>) throws -> URL {
        var found: URL?
        try brokerPoll(10) {
            let files = FileManager.default.enumerator(at: rig.home.url.appendingPathComponent("runs"),
                includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                let run = file.deletingLastPathComponent()
                if file.lastPathComponent == "u6d.proxy", !excluding.contains(run.path) { found = run }
            }
            return found != nil
        }
        return try #require(found)
    }

    static func address(_ port: Int) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = UInt16(port).bigEndian
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        return value
    }

    static func configure(_ fd: Int32) throws {
        var noPipe: Int32 = 1
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, 4) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0
        else { throw BrokerFailure("socket options failed") }
    }

    static func listener() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerFailure("socket failed") }
        do {
            try configure(fd)
            var value = address(0)
            let bound = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else { throw BrokerFailure("listen failed") }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            guard named == 0 else { throw BrokerFailure("getsockname failed") }
            return (fd, Int(UInt16(bigEndian: value.sin_port)))
        } catch { close(fd); throw error }
    }

    static func readable(_ fd: Int32, milliseconds: Int32 = 3000) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, milliseconds)
        guard result >= 0 else { throw BrokerFailure("poll failed") }
        return result > 0
    }

    static func accept(_ fd: Int32) throws -> Int32 {
        guard try readable(fd) else { throw BrokerFailure("accept deadline exceeded") }
        let peer = Darwin.accept(fd, nil, nil)
        guard peer >= 0 else { throw BrokerFailure("accept failed") }
        do { try configure(peer); return peer } catch { close(peer); throw error }
    }

    static func ipv6Address(_ port: Int) -> sockaddr_in6 {
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = UInt16(port).bigEndian
        value.sin6_addr = in6addr_loopback
        return value
    }

    static func bindError(_ port: Int, ipv6: Bool) throws -> Int32 {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerFailure("socket failed") }
        defer { close(fd) }
        let result: Int32
        if ipv6 {
            var value = ipv6Address(port)
            result = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var value = address(port)
            result = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == 0 ? 0 : errno
    }

    static func connectionAttempt(_ port: Int, ipv6: Bool = false) -> (fd: Int32, error: Int32) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, errno) }
        do { try configure(fd) } catch { close(fd); return (-1, EINVAL) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let failure = errno
            close(fd)
            return (-1, failure)
        }
        let result: Int32
        if ipv6 {
            var value = ipv6Address(port)
            result = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var value = address(port)
            result = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var failure: Int32 = result == 0 ? 0 : errno
        if failure == EINPROGRESS {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 3000)
            if ready > 0 {
                var size = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) != 0 { failure = errno }
            } else {
                failure = ready == 0 ? ETIMEDOUT : errno
            }
        }
        if failure != 0 { close(fd); return (-1, failure) }
        guard fcntl(fd, F_SETFL, 0) == 0 else {
            let failure = errno
            close(fd)
            return (-1, failure)
        }
        return (fd, 0)
    }

    static func connect(_ port: Int) throws -> Int32 {
        let result = connectionAttempt(port)
        guard result.error == 0 else { throw BrokerFailure("connect failed: \(result.error)") }
        return result.fd
    }

    static func send(_ fd: Int32, _ text: String) throws {
        let deadline = ContinuousClock.now + .seconds(5)
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard ContinuousClock.now < deadline else { throw BrokerFailure("send deadline exceeded") }
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw BrokerFailure("send failed") }
                offset += count
            }
        }
    }

    static func receive(_ fd: Int32, count: Int) throws -> String {
        var data = Data(), byte: UInt8 = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while data.count < count {
            guard ContinuousClock.now < deadline, read(fd, &byte, 1) == 1 else {
                throw BrokerFailure("receive failed or deadline exceeded")
            }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func head(_ fd: Int32) throws -> String {
        var data = Data(), byte: UInt8 = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while data.count < 8192, ContinuousClock.now < deadline {
            guard read(fd, &byte, 1) == 1 else { throw BrokerFailure("incomplete response head") }
            data.append(byte)
            if data.suffix(4) == Data("\r\n\r\n".utf8) { return String(decoding: data, as: UTF8.self) }
        }
        throw BrokerFailure("response head deadline or size exceeded")
    }

    static func untilClosed(_ fd: Int32) throws -> String {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, data.count < 16384 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 || (count < 0 && errno == ECONNRESET) { return String(decoding: data, as: UTF8.self) }
            guard count > 0 else { throw BrokerFailure("connection did not close") }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw BrokerFailure("close deadline or size exceeded")
    }
}
