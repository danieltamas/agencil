import Darwin
import Foundation
import Testing

func u6aSeat(_ name: String = "primary", _ harness: String = "codex",
             extra: [String: Any] = [:]) -> [String: Any] {
    ["name": name, "harness": harness, "model": "test-model", "role": "answerer",
     "hardening": [], "cap": ["seconds": 20, "tokens": 37]].merging(extra) { _, b in b }
}
func u6aRoute(_ target: String = "primary", callers: [String] = ["owner"],
              fallbacks: [String] = []) -> [String: Any] {
    ["callers": callers, "target": target, "hop_limit": 2, "fallbacks": fallbacks]
}
func u6aText(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

final class U6aRig {
    let home: BrokerHome
    let bin: URL
    let record: URL
    var broker: BrokerProcess?
    init(_ kinds: [String] = ["codex"], mode: String = "answer") throws {
        home = try BrokerHome()
        bin = home.url.appendingPathComponent("bin")
        record = home.url.appendingPathComponent("record")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for kind in kinds { try install(kind) }
        try config()
        broker = try home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": bin.path,
                                 "STUB_MODE": mode, "STUB_RECORD": record.path])
    }
    deinit {
        // Kill fixture groups even if an assertion or the broker failed midway.
        if let pids = try? contents(".allpids").split(separator: "\n").compactMap({ Int32($0) }) {
            for (index, pid) in pids.enumerated() {
                if index.isMultiple(of: 2) { brokerGroupCleanup(pid) }
                if brokerAlive(pid) { Darwin.kill(pid, SIGKILL) }
            }
        }
        broker?.kill()
    }
    @discardableResult
    func install(_ kind: String, directory: URL? = nil, version: String = "0.9.4") throws -> URL {
        let directory = directory ?? bin
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = try String(contentsOf: brokerFixture("u6a-seat.sh"), encoding: .utf8)
            .replacingOccurrences(of: "version=0.9.4", with: "version=" + version)
        let path = directory.appendingPathComponent(kind)
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    func config(seats: [[String: Any]] = [u6aSeat()], routes: [[String: Any]] = [u6aRoute()],
                aliases: [String: String] = [:], raw: [String: String] = [:]) throws {
        let values = try ["seats": u6aText(seats), "routes": u6aText(routes), "aliases": u6aText(aliases)]
            .merging(raw) { _, b in b }
        try JSONSerialization.data(withJSONObject: ["revision": 1, "values": values])
            .write(to: home.url.appendingPathComponent("config.json"), options: .atomic)
    }
    func ask(_ target: String = "primary", question: String = "test question", caller: String = "owner",
             extra: [String: Any] = [:]) throws -> [String: Any] {
        try home.request(["op": "ask", "caller": caller, "target": target, "question": question,
                          "wait_seconds": 10].merging(extra) { _, b in b })
    }
    func data(_ reply: [String: Any]) throws -> [String: Any] {
        #expect(reply["ok"] as? Bool == true)
        return try #require(reply["data"] as? [String: Any])
    }
    func answered(_ reply: [String: Any], seat: String = "primary") throws -> [String: Any] {
        let result = try data(reply)
        #expect(result["state"] as? String == "answered")
        #expect(result["answer"] as? String == "u6a answer")
        #expect(result["seat"] as? String == seat)
        let id = try #require(result["thread"] as? String)
        #expect(id.range(of: "^th_[0-9a-fA-F]{16}$", options: .regularExpression) != nil)
        return result
    }
    func refused(_ reply: [String: Any], _ reason: String, exit: Int = 4) {
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == exit)
        #expect(reply["error"] as? String == reason)
    }
    func contents(_ suffix: String = "") throws -> String {
        try String(contentsOf: URL(fileURLWithPath: record.path + suffix), encoding: .utf8)
    }
    func noAnswerSpawned() {
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }
    func cliData(_ args: [String], exit: Int32 = 0) throws -> [String: Any] {
        let (code, out, _) = try home.cli(args + ["--json"])
        #expect(code == exit)
        return try #require(brokerJSON(Data(out.utf8))["data"] as? [String: Any])
    }
}

// Real loopback HTTP peer, intentionally independent of the broker's HTTP implementation.
final class U6aHTTP: @unchecked Sendable {
    let fd: Int32
    let endpoint: String
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var stopped = false
    private let group = DispatchGroup()
    init(models: [String] = ["test-model"]) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        fd = socketFD
        guard socketFD >= 0 else { throw BrokerFailure("HTTP socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, addressSize) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw BrokerFailure("HTTP bind") }
        var length = socklen_t(MemoryLayout.size(ofValue: addr))
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        endpoint = "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))"
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            while true {
                let client = accept(socketFD, nil, nil)
                if client < 0 { break }
                serve(client, models: models)
                close(client)
            }
        }
    }
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        if !alreadyStopped { shutdown(fd, SHUT_RDWR); close(fd); group.wait() }
    }
    func requests() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return received }
    private func serve(_ client: Int32, models: [String]) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var bytes = Data(), byte: UInt8 = 0
        while read(client, &byte, 1) == 1 {
            bytes.append(byte)
            if bytes.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        let header = String(decoding: bytes, as: UTF8.self)
        let count = header.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("content-length:")
        }.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        var body = Data()
        for _ in 0..<count { if read(client, &byte, 1) != 1 { return }; body.append(byte) }
        let isChat = header.hasPrefix("POST /api/chat ")
        if isChat, let json = try? brokerJSON(body) { lock.lock(); received.append(json); lock.unlock() }
        let payload: [String: Any] = isChat ? ["message": ["content": "u6a answer"], "done": true] :
            ["models": models.map { ["name": $0, "model": $0] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        var noPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, 4)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }; offset += n
            }
        }
    }
}
