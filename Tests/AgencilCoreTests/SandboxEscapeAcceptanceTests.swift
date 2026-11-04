@testable import AgencilCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct SandboxEscapeAcceptanceTests {
    private static let ownerOps = ["panel", "detail", "findings", "costs", "data", "leaderboard",
        "budgets", "adjudicate", "prune", "proposals"]

    @Test func productionBrokerDoesNotExposeLaunch() throws {
        let home = try BrokerHome()
        let broker = try home.serve(["AGENCIL_TEST_SEAMS": "0"])
        defer { broker.kill() }
        let marker = home.url.appendingPathComponent("escaped")
        let reply = try home.request(["op": "launch", "argv": ["/usr/bin/touch", marker.path],
            "cwd": home.url.path, "env": [:], "reservation": ["seconds": 10]])
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["error"] as? String == "unknown op launch")
        #expect(reply["exit"] as? Int == 64)
        // Stop and reap the server before checking for an asynchronous spawn.
        broker.kill(SIGTERM); _ = try broker.finish()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func child(_ r: U25Rig, request: [String: Any]) throws -> [String: Any] {
        try r.installChildWakeStubs()
        let url = r.base.bin.appendingPathComponent("codex")
        let script = try r.text(url)
        let command = "\"$STUB_CLI\" wake panel --brief \"$STUB_DIR/child.brief\" --wait 15 --json"
        try #require(script.contains(command))
        var wire = request
        wire["caller"] = request["caller"] ?? "owner"
        // nc is a real descendant of a live seat, not a forged PID or caller label.
        let json = try u6aText(wire).replacingOccurrences(of: "'", with: "'\\''")
        let raw = "printf '%s\\n' '" + json + "' | /usr/bin/nc -w 3 -U \"$AGENCIL_HOME/agencil.sock\""
        try script.replacingOccurrences(of: command, with: raw)
            .write(to: url, atomically: false, encoding: .utf8)
        try r.put("codex.ask.child")
        let parent = try r.data(r.base.ask("a"))
        #expect(parent["state"] as? String == "answered")
        return try brokerJSON(Data(r.observation("codex", "ask", suffix: "child").utf8))
    }

    @Test(arguments: ownerOps)
    func seatDescendantCannotUseOwnerOperation(op: String) throws {
        let r = try U25Rig()
        let reply = try child(r, request: ["op": op])
        try r.failure(reply, exit: 3, contains: ["refused:"])
        #expect(reply["data"] == nil)
    }

    @Test(arguments: ownerOps)
    func unknownAncestryFailsClosed(op: String) throws {
        let r = try U25Rig()
        try r.restart(environment: ["AGENCIL_TEST_FAIL_ANCESTRY": "peer"])
        try r.failure(r.request(op), exit: 3, contains: ["refused:"])
    }

    @Test func childAllowlistStillUsesRoutesAndAgentAccess() throws {
        let r = try U25Rig()
        let ask = try child(r, request: ["op": "ask", "target": "b", "question": "inspect harbor"])
        // A blanket child refusal would not name the attributed seat and route.
        #expect(ask["error"] as? String == "refused: no route from a to b")
        #expect(ask["exit"] as? Int == 3)
        // Each invocation has its own observations; use a fresh rig for the next child.
        let listed = try U25Rig()
        let reply = try child(listed, request: ["op": "list_targets", "caller": "a"])
        if reply["ok"] as? Bool != true {
            #expect(reply["ok"] as? Bool == false)
            #expect(reply["error"] as? String == "refused: agent access is off")
            #expect(reply["exit"] as? Int == 3)
        }
        #expect(reply["error"] as? String != "refused: a seat cannot do this")
    }

    @Test func rootCallerStillReadsAndPrunes() throws {
        let r = try U25Rig()
        let thread = try #require(r.data(r.base.ask("a"))["thread"] as? String)
        for op in Self.ownerOps where op != "adjudicate" {
            let fields: [String: Any]
            switch op {
            case "detail": fields = ["id": thread]
            case "leaderboard": fields = ["action": "preview"]
            default: fields = [:]
            }
            #expect(try r.request(op, fields)["ok"] as? Bool == true, "root op: \(op)")
        }
        let fixture = try u24Fixture()
        let adjudicator = try U23Rig(fixture, answer: "CONFIRMED\nthe guard is missing")
        #expect(try u24Adjudicate(adjudicator)["ok"] as? Bool == true)
    }

    private func profile(_ home: BrokerHome, brokerHome: URL) throws -> String {
        let copy = home.url.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        return Confinement.profile(copy: copy.path, runDirectory: home.url.path,
            executable: "/usr/bin/python3", harness: "codex",
            home: home.url.path, brokerHome: brokerHome.path)
    }

    @Test func unixSocketDenyFollowsGeneralNetworkAllow() throws {
        let home = try BrokerHome()
        let brokerHome = home.url.appendingPathComponent("broker")
        let text = try profile(home, brokerHome: brokerHome)
        let allow = try #require(text.range(of: "(allow network*)", options: .backwards))
        let tail = String(text[allow.upperBound...])
        #expect(tail.range(of: #"\(deny network\*[\s\S]*unix-socket[\s\S]*\(subpath "\#(brokerHome.path)"\)"#,
            options: .regularExpression) != nil)
    }

    private static let sandboxAvailable: Bool = {
        let p = Process(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        p.standardError = errors
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 { return true }
            print("sandbox-exec cannot apply a profile: " +
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        } catch { print("sandbox-exec unavailable: \(error)") }
        return false
    }()

    @Test(.enabled(if: sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func realSandboxDeniesBrokerSocketButAllowsUnrelatedSocket() throws {
        let home = try BrokerHome(), outside = try BrokerHome()
        let brokerHome = home.url.appendingPathComponent("broker")
        try FileManager.default.createDirectory(at: brokerHome, withIntermediateDirectories: true)
        let denied = brokerHome.appendingPathComponent("peer.sock")
        let allowed = outside.url.appendingPathComponent("peer.sock")
        let servers = try [denied, allowed].map { try UnixListener($0) }
        defer { for server in servers { close(server.fd) } }
        let path = home.url.appendingPathComponent("seat.sb")
        try profile(home, brokerHome: brokerHome).write(to: path, atomically: true, encoding: .utf8)
        let code = "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1])"
        func connect(_ socket: URL) throws -> (Int32, String, String) {
            let p = try BrokerProcess(["-f", path.path, "/usr/bin/python3", "-I", "-c", code, socket.path],
                home: home.url, executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"))
            return try p.finish(15)
        }
        // Positive control rules out interpreter, profile and server failures.
        let success = try connect(allowed)
        #expect(success.0 == 0, "\(success)")
        let failure = try connect(denied)
        #expect(failure.0 != 0)
        #expect(failure.2.contains("PermissionError"))
        #expect(failure.2.contains("Operation not permitted") || failure.2.contains("Permission denied"))
    }
}

private struct UnixListener {
    let fd: Int32
    init(_ url: URL) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerFailure("listener socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd); throw BrokerFailure("listener path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd); throw BrokerFailure("listener bind/listen failed")
        }
    }
}
