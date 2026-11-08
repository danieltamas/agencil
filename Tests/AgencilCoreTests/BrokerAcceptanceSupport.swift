// Black-box U5 contract. No private ledger tables are inspected.
// Seams: AGENCIL_TEST_PAUSE_AFTER_SPAWN=1 pauses before registration and writes
// $AGENCIL_HOME/test-spawn.json {run,pid,pgid,nonce}; the launch intent is already durable.
// AGENCIL_TEST_FORGE_START_TIME=1 records an intentionally wrong start time for launch.
// AGENCIL_TEST_RECOVERY_HOLD=1 sends TERM but defers KILL until the test sends it;
// it must continue serving status while the reservation remains held.
// Protocol fields: ping {ok,peer_pid}; launch {ok,run,pid,pgid}; status
// {state,reserved,registered_at,pid,pgid,start_time}; timestamps are Unix seconds.
// Config override: AGENCIL_MCP_CONFIG_DIR/{codex/config.toml,opencode/opencode.json}.
// Other files: config.json, installed.json, broker.lock, agencil.sock, test-spawn.json.
import Foundation
import Darwin
import Testing

struct BrokerFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func brokerPoll(_ seconds: Double = 30, _ condition: () throws -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    repeat {
        if try condition() { return }
        usleep(10_000)
    } while ContinuousClock.now < deadline
    throw BrokerFailure("Deadline exceeded after \(seconds)s")
}

final class BrokerProcess {
    let process = Process()
    let input = Pipe()
    let output: FileHandle
    let errors: FileHandle
    private let outURL: URL
    private let errURL: URL
    init(_ argv: [String], home: URL, env: [String: String] = [:], executable: URL? = nil) throws {
        outURL = home.appendingPathComponent(UUID().uuidString)
        errURL = home.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        output = try FileHandle(forUpdating: outURL)
        errors = try FileHandle(forUpdating: errURL)
        process.executableURL = try executable ?? brokerBinary()
        process.arguments = argv
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["AGENCIL_HOME": home.path].merging(env) { _, b in b }) { _, b in b }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
    }
    func outputSnapshot() throws -> Data { try Data(contentsOf: outURL) }
    func finish(_ timeout: Double = 30) throws -> (Int32, String, String) {
        try brokerPoll(timeout) { !process.isRunning }
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: outURL, encoding: .utf8),
                try String(contentsOf: errURL, encoding: .utf8))
    }
    func kill(_ signal: Int32 = SIGKILL) {
        if process.isRunning { Darwin.kill(process.processIdentifier, signal) }
    }
    deinit {
        kill()
        process.waitUntilExit()
        try? input.fileHandleForWriting.close()
        try? output.close(); try? errors.close()
    }
}

func brokerBinary() throws -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    var candidates = [executable.deletingLastPathComponent().appendingPathComponent("AgencilCLI")]
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("AgencilCLI"))
    }
    if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
       CommandLine.arguments.indices.contains(index + 1) {
        var path = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        while path.path != "/" {
            if path.pathExtension == "xctest" {
                candidates.append(path.deletingLastPathComponent().appendingPathComponent("AgencilCLI"))
                break
            }
            path.deleteLastPathComponent()
        }
    }
    guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw BrokerFailure("Missing AgencilCLI next to test bundle; build AgencilCLI before running BrokerAcceptanceTests")
    }
    return binary
}

final class BrokerHome: @unchecked Sendable {
    let directory: AcceptanceDirectory
    let url: URL
    init() throws {
        directory = try AcceptanceDirectory()
        // Reuse the established directory helper while keeping Unix socket paths short.
        url = URL(fileURLWithPath: "/tmp/a" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url); directory.remove() }
    func cli(_ args: [String], env: [String: String] = [:]) throws -> (Int32, String, String) {
        let p = try BrokerProcess(args, home: url, env: env)
        return try p.finish()
    }
    func serve(_ env: [String: String] = [:]) throws -> BrokerProcess {
        let p = try BrokerProcess(["serve"], home: url, env: ["AGENCIL_TEST_SEAMS": "1"].merging(env) { _, value in value })
        try brokerPoll { (try? self.request(["op": "ping"])["ok"] as? Bool) == true }
        return p
    }
    func request(_ object: [String: Any], socketName: String = "agencil.sock") throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerFailure("socket failed") }
        defer { close(fd) }
        var noPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, 4) == 0 else { throw BrokerFailure("setsockopt failed") }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.appendingPathComponent(socketName).path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BrokerFailure("Socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw BrokerFailure("connect failed") }
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                guard n > 0 else { throw BrokerFailure("socket write failed") }
                sent += n
            }
        }
        var response = Data(), byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 10 { response.append(byte) }
        return try brokerJSON(response)
    }
    func launch(_ mode: String = "leader", extra: [String: String] = [:]) throws -> [String: Any] {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/u5-seat.sh")
        return try request(["op": "launch", "argv": ["/bin/sh", fixture.path, mode],
                            "cwd": url.path, "env": ["MARKER": url.appendingPathComponent("marker").path]
                                .merging(extra) { _, b in b }, "reservation": ["seconds": 120]])
    }
    func status(_ run: String) throws -> [String: Any] { try request(["op": "status", "run": run]) }
    func marker() throws -> [String] {
        try String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

func brokerJSON(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BrokerFailure("Expected JSON object")
    }
    return object
}
func brokerAlive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }
func brokerGroupCleanup(_ pgid: Int32) { if pgid > 1 { Darwin.kill(-pgid, SIGKILL) } }
func brokerInt(_ object: [String: Any], _ key: String) throws -> Int32 {
    guard let n = object[key] as? NSNumber else { throw BrokerFailure("Missing integer \(key): \(object)") }
    return n.int32Value
}

func brokerFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
}
