@testable import AgencilCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U38ProxyAcceptanceTests {
    @Test func adapterChangesOnlyCodexSandboxValue() throws {
        let home = try BrokerHome()
        for harness in ["codex", "claude", "opencode"] {
            let seat = try SeatConfig(values: ["seats": u6aText([u6aSeat("s", harness)])]).seats[0]
            let plain = try #require(try Adapter.command(seat: seat, executable: "/x", prompt: "p",
                answerFile: home.url.appendingPathComponent("answer").path, runDirectory: home.url.path))
            let confined = try #require(try Adapter.command(seat: seat, executable: "/x", prompt: "p",
                answerFile: home.url.appendingPathComponent("answer").path, runDirectory: home.url.path,
                ownSandbox: false))
            if harness == "codex" {
                let index = try #require(plain.argv.firstIndex(of: "-s"))
                try #require(plain.argv.indices.contains(index + 1))
                #expect(plain.argv[index + 1] == "read-only")
                #expect(!confined.argv.contains("read-only"))
                var expected = plain.argv
                expected[index + 1] = "danger-full-access"
                #expect(confined.argv == expected)
            } else {
                #expect(confined.argv == plain.argv)
            }
        }
    }

    @Test func profileRestrictsEgressAndRetainsBrokerDenials() throws {
        let home = try BrokerHome(), root = home.url
        let broker = root.appendingPathComponent("broker")
        try FileManager.default.createDirectory(at: broker, withIntermediateDirectories: true)
        let restricted = U38ProxySocket.profile(root, port: 4321)
        #expect(restricted.contains("(allow network-outbound (remote tcp \"localhost:4321\"))"))
        #expect(!restricted.contains("(allow network*)"))
        let denials = restricted.split(separator: "\n").filter { $0.contains("(deny network*") }
        #expect(denials.count == 2)
        for path in [broker.path, U34Support.resolved(broker)] {
            #expect(denials.contains { $0.contains("(remote unix-socket (subpath \"\(path)\"))") })
        }
        let unrestricted = U34Support.profile(root)
        #expect(unrestricted.contains("(allow network*)"))
        #expect(!unrestricted.contains("(allow network-outbound"))
    }

    @Test func egressHostsAndEnvironmentAreExact() {
        #expect(Egress.hosts(for: "codex") == Set(["chatgpt.com", "api.openai.com", "auth.openai.com"]))
        for harness in ["claude", "opencode", "hermes", "ollama"] {
            #expect(Egress.hosts(for: harness) == nil)
        }
        var expected = ["NO_PROXY": "", "no_proxy": ""]
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"] {
            expected[key] = "http://127.0.0.1:9"
        }
        #expect(Egress.environment(port: 9) == expected)
    }

    @Test func proxyTunnelsAllowedHostIgnoringCase() throws {
        let echo = try U38ProxySocket.listener()
        defer { close(echo.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"], allowedPort: echo.port)
        defer { proxy.stop() }
        for host in ["localhost", "LOCALHOST"] {
            let client = try U38ProxySocket.connect(proxy.port)
            defer { close(client) }
            try U38ProxySocket.send(client, "CONNECT \(host):\(echo.port) HTTP/1.1\r\n\r\n")
            #expect(try U38ProxySocket.head(client).hasPrefix("HTTP/1.1 200 "))
            let peer = try U38ProxySocket.accept(echo.fd)
            defer { close(peer) }
            let payload = "tunnel-\(host)"
            try U38ProxySocket.send(client, payload)
            let received = try U38ProxySocket.receive(peer, count: payload.utf8.count)
            #expect(received == payload)
            try U38ProxySocket.send(peer, received)
            #expect(try U38ProxySocket.receive(client, count: payload.utf8.count) == payload)
        }
    }

    @Test func proxyRejectsOtherTargetsMethodsAndOversizedHeads() throws {
        let echo = try U38ProxySocket.listener(), other = try U38ProxySocket.listener()
        defer { close(echo.fd); close(other.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"], allowedPort: echo.port)
        defer { proxy.stop() }
        for target in ["127.0.0.1:\(echo.port)", "localhost.:\(echo.port)",
                       "localhost:\(other.port)", "evil.example:\(echo.port)"] {
            let client = try U38ProxySocket.connect(proxy.port)
            defer { close(client) }
            try U38ProxySocket.send(client, "CONNECT \(target) HTTP/1.1\r\n\r\n")
            #expect(try U38ProxySocket.head(client).hasPrefix("HTTP/1.1 403 "))
            #expect(try !U38ProxySocket.readable(echo.fd, milliseconds: 100))
            #expect(try !U38ProxySocket.readable(other.fd, milliseconds: 100))
        }
        let get = try U38ProxySocket.connect(proxy.port)
        defer { close(get) }
        try U38ProxySocket.send(get, "GET http://localhost:\(echo.port)/ HTTP/1.1\r\n\r\n")
        #expect(try U38ProxySocket.head(get).hasPrefix("HTTP/1.1 405 "))
        let oversized = try U38ProxySocket.connect(proxy.port)
        defer { close(oversized) }
        try U38ProxySocket.send(oversized, String(repeating: "x", count: 9000))
        let response = try U38ProxySocket.untilClosed(oversized)
        #expect(!response.contains("200"))
        #expect(try !U38ProxySocket.readable(echo.fd, milliseconds: 100))
    }

    @Test func proxyListenersBindOnlyBothLoopbacksOnSamePort() throws {
        let home = try BrokerHome()
        let proxy = try EgressProxy(allowedHosts: ["localhost"])
        defer { proxy.stop() }
        let process = try BrokerProcess(["-nP", "-a", "-p", String(getpid()),
            "-iTCP:\(proxy.port)", "-sTCP:LISTEN", "-Fn"], home: home.url,
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"))
        let result = try process.finish(5)
        #expect(result.0 == 0, "\(result)")
        let names = result.1.split(separator: "\n").filter { $0.hasPrefix("n") }
        #expect(names.count == 2)
        #expect(Set(names.map(String.init)) == ["n127.0.0.1:\(proxy.port)", "n[::1]:\(proxy.port)"])
    }

    @Test(arguments: [false, true])
    func proxyHoldsBothLoopbackAddresses(ipv6: Bool) throws {
        let proxy = try EgressProxy(allowedHosts: ["localhost"])
        defer { proxy.stop() }
        #expect(try U38ProxySocket.bindError(proxy.port, ipv6: ipv6) == EADDRINUSE)
    }

    @Test func proxyTunnelsConnectOverIPv6Loopback() throws {
        let echo = try U38ProxySocket.listener()
        defer { close(echo.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"], allowedPort: echo.port)
        defer { proxy.stop() }
        let connection = U38ProxySocket.connectionAttempt(proxy.port, ipv6: true)
        try #require(connection.error == 0)
        let client = connection.fd
        defer { close(client) }
        try U38ProxySocket.send(client, "CONNECT localhost:\(echo.port) HTTP/1.1\r\n\r\n")
        #expect(try U38ProxySocket.head(client).hasPrefix("HTTP/1.1 200 "))
        let peer = try U38ProxySocket.accept(echo.fd)
        defer { close(peer) }
        try U38ProxySocket.send(client, "ipv6-tunnel")
        let payload = try U38ProxySocket.receive(peer, count: 11)
        #expect(payload == "ipv6-tunnel")
        try U38ProxySocket.send(peer, payload)
        #expect(try U38ProxySocket.receive(client, count: 11) == payload)
    }

    @Test(arguments: [false, true])
    func proxyRejectsOversizedTerminatedHead(splitBlankLine: Bool) throws {
        let echo = try U38ProxySocket.listener()
        defer { close(echo.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"], allowedPort: echo.port)
        defer { proxy.stop() }
        let client = try U38ProxySocket.connect(proxy.port)
        defer { close(client) }
        let prefix = "CONNECT localhost:\(echo.port) HTTP/1.1\r\nX-Pad: "
        // Only the final blank line pushes this otherwise valid head over the limit.
        let partial = prefix + String(repeating: "x", count: 8191 - prefix.utf8.count - 2) + "\r\n"
        let head = partial + "\r\n"
        #expect(head.utf8.count == 8193)
        if splitBlankLine {
            try U38ProxySocket.send(client, partial)
            #expect(try !U38ProxySocket.readable(client, milliseconds: 100))
            try U38ProxySocket.send(client, "\r\n")
        } else {
            try U38ProxySocket.send(client, head)
        }
        #expect(try !U38ProxySocket.untilClosed(client).contains("200"))
        #expect(try !U38ProxySocket.readable(echo.fd, milliseconds: 100))
    }

    @Test func proxyAcceptsHeadOfExactly8192BytesIncludingBlankLine() throws {
        let echo = try U38ProxySocket.listener()
        defer { close(echo.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"], allowedPort: echo.port)
        defer { proxy.stop() }
        let client = try U38ProxySocket.connect(proxy.port)
        defer { close(client) }
        let prefix = "CONNECT localhost:\(echo.port) HTTP/1.1\r\nX-Pad: "
        let head = prefix + String(repeating: "x", count: 8192 - prefix.utf8.count - 4) + "\r\n\r\n"
        #expect(head.utf8.count == 8192)
        try U38ProxySocket.send(client, head)
        #expect(try U38ProxySocket.head(client).hasPrefix("HTTP/1.1 200 "))
        let peer = try U38ProxySocket.accept(echo.fd)
        close(peer)
    }

    @Test func stopClosesClientWithPartialHead() throws {
        let proxy = try EgressProxy(allowedHosts: ["localhost"])
        var stopped = false
        defer { if !stopped { proxy.stop() } }
        let client = try U38ProxySocket.connect(proxy.port)
        defer { close(client) }
        try U38ProxySocket.send(client, "CONNECT localhost:443 HTTP/1.1\r\nX-Partial: ")
        #expect(try !U38ProxySocket.readable(client, milliseconds: 100))
        proxy.stop()
        stopped = true
        #expect(try !U38ProxySocket.untilClosed(client).contains("200"))
    }

    @Test func stopRefusesNewConnectionsAndClosesOpenTunnel() throws {
        let echo = try U38ProxySocket.listener()
        defer { close(echo.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"], allowedPort: echo.port)
        var stopped = false
        defer { if !stopped { proxy.stop() } }
        let client = try U38ProxySocket.connect(proxy.port)
        defer { close(client) }
        try U38ProxySocket.send(client, "CONNECT localhost:\(echo.port) HTTP/1.1\r\n\r\n")
        #expect(try U38ProxySocket.head(client).hasPrefix("HTTP/1.1 200 "))
        let peer = try U38ProxySocket.accept(echo.fd)
        defer { close(peer) }
        proxy.stop()
        stopped = true
        _ = try U38ProxySocket.untilClosed(client)
        _ = try U38ProxySocket.untilClosed(peer)
        let connection = U38ProxySocket.connectionAttempt(proxy.port)
        if connection.fd >= 0 { close(connection.fd) }
        #expect(connection.error == ECONNREFUSED)
    }

    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func realSandboxAllowsOnlyProxyPort() throws {
        let home = try BrokerHome(), other = try U38ProxySocket.listener()
        defer { close(other.fd) }
        let proxy = try EgressProxy(allowedHosts: ["localhost"])
        defer { proxy.stop() }
        let code = """
        import socket,sys
        s=socket.socket(); s.settimeout(3)
        s.connect(('127.0.0.1', int(sys.argv[1]))); s.close()
        s=socket.socket(); s.settimeout(3)
        try:
            s.connect(('127.0.0.1', int(sys.argv[2])))
        except OSError:
            pass
        else:
            raise AssertionError('other loopback port reachable')
        finally:
            s.close()
        """
        let result = try U34Support.python(home.url, profile: U38ProxySocket.profile(home.url, port: proxy.port),
            code: code, arguments: [String(proxy.port), String(other.port)])
        #expect(result.0 == 0, "\(result)")
        #expect(try !U38ProxySocket.readable(other.fd, milliseconds: 100))
    }

    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func brokerConfinedCodexUsesAndReusesProxyButUnconfinedDoesNot() throws {
        let rig = try U6dRig()
        defer { try? FileManager.default.removeItem(at: rig.home.url.appendingPathComponent("egress-codex.json")) }
        try U38ProxySocket.recordEnvironment(rig, harness: "codex")
        try rig.repository()
        var ports: [Int] = [], observed: Set<String> = []
        for _ in 0..<2 {
            _ = try rig.base.answered(rig.ask())
            let run = try U38ProxySocket.observedRun(rig, excluding: observed)
            observed.insert(run.path)
            let argv = try String(contentsOf: run.appendingPathComponent("u6d.argv"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let index = try #require(argv.firstIndex(of: "-s"))
            #expect(argv.dropFirst(index + 1).first == "danger-full-access")
            let environment = try String(contentsOf: run.appendingPathComponent("u6d.proxy"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let port = try #require(Int(environment.replacingOccurrences(of: "http://127.0.0.1:", with: "")))
            #expect(environment == "http://127.0.0.1:\(port)")
            let profile = try String(contentsOf: run.appendingPathComponent("confine.sb"), encoding: .utf8)
            #expect(profile.contains("(allow network-outbound (remote tcp \"localhost:\(port)\"))"))
            #expect(!profile.contains("(allow network*)"))
            let client = try U38ProxySocket.connect(port)
            close(client)
            ports.append(port)
        }
        #expect(ports[0] == ports[1])
        _ = try rig.base.answered(rig.ask(repo: false))
        let argv = try rig.base.contents(".argv").split(separator: "\n").map(String.init)
        let index = try #require(argv.firstIndex(of: "-s"))
        #expect(argv.dropFirst(index + 1).first == "read-only")
        #expect(try rig.base.contents(".proxy") == "unset\n")
    }

    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func brokerConfinedClaudeKeepsNetworkAndHasNoProxy() throws {
        let rig = try U6dRig()
        try rig.configure([u6aSeat("primary", "claude")])
        try U38ProxySocket.recordEnvironment(rig, harness: "claude")
        try rig.repository()
        _ = try rig.base.answered(rig.ask())
        let run = try U38ProxySocket.observedRun(rig, excluding: [])
        let profile = try String(contentsOf: run.appendingPathComponent("confine.sb"), encoding: .utf8)
        #expect(profile.contains("(allow network*)"))
        #expect(try String(contentsOf: run.appendingPathComponent("u6d.proxy"), encoding: .utf8) == "unset\n")
    }
}
