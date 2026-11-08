import Darwin
import Foundation
import Testing

func u6cBudget(_ name: String = "cap", scope: String = "route", key: String = "primary",
               dollars: Double? = nil, tokens: Int? = nil, hard: Bool = true) -> [String: Any] {
    var b: [String: Any] = ["name": name, "scope": scope, "key": key, "window": "lifetime", "hard": hard]
    if let dollars { b["dollars"] = dollars }
    if let tokens { b["tokens"] = tokens }
    return b
}

final class U6cRig: @unchecked Sendable {
    let base: U6aRig
    var home: BrokerHome { base.home }
    init(mode: String = "answer", memory: Int? = nil) throws {
        base = try U6aRig()
        base.broker?.kill(); _ = try base.broker?.finish()
        let path = base.bin.appendingPathComponent("codex")
        try Data(contentsOf: brokerFixture("u6c-seat.sh")).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        var env = ["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": base.bin.path,
                   "STUB_RECORD": base.record.path, "STUB_MODE": mode]
        if let memory { env["AGENCIL_TEST_FREE_MEMORY_MB"] = String(memory) }
        base.broker = try home.serve(env)
    }
    func configure(_ seats: [[String: Any]] = [u6aSeat()], budgets: [[String: Any]] = [],
                   limits: [String: Int] = [:], routes: [[String: Any]] = [u6aRoute()]) throws {
        try base.config(seats: seats, routes: routes,
                        raw: ["budgets": u6aText(budgets), "limits": u6aText(limits)])
    }
    func budgets() throws -> [[String: Any]] {
        let d = try base.data(home.request(["op": "budgets"]))
        return try #require(d["budgets"] as? [[String: Any]])
    }
    func sql(_ query: String) throws -> String {
        let p = try BrokerProcess(["-readonly", home.url.appendingPathComponent("agencil.sqlite").path, query],
                                  home: home.url, executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
        let result = try p.finish(); #expect(result.0 == 0); return result.1
    }
    func refusedWithoutRun(_ reason: String) throws {
        base.refused(try base.ask(), "refused: " + reason, exit: 3)
        #expect(try sql("SELECT count(*) FROM requests; SELECT count(*) FROM runs; SELECT count(*) FROM reservations;") == "1\n0\n0\n")
        #expect(try sql(".dump requests").contains("refused"))
        base.noAnswerSpawned()
    }
    func release() throws { try Data().write(to: URL(fileURLWithPath: base.record.path + ".release")) }
}

func u6cNumber(_ d: [String: Any], _ key: String) throws -> Double {
    try #require(d[key] as? NSNumber).doubleValue
}
func u6cWithinLimits(_ rows: [[String: Any]]) throws {
    for row in rows where row["hard"] as? Bool == true {
        for unit in ["dollars", "tokens"] {
            if let limit = row[unit + "_limit"] as? NSNumber {
                #expect(try u6cNumber(row, "spent_" + unit) + u6cNumber(row, "reserved_" + unit) <= limit.doubleValue + 1e-9)
            }
        }
    }
}

// Independent extension of the U6aHTTP wire fixture: instant responses, captured bodies,
// provider counters, deterministic HTTP failures. No production HTTP code is reused.
final class U6cHTTP: @unchecked Sendable {
    let fd: Int32
    let endpoint: String
    let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private let group = DispatchGroup()
    var usage = true
    var fail = false
    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let f = fd
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(f, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard bound == 0, listen(f, 32) == 0 else { close(f); throw BrokerFailure("HTTP bind") }
        var n = socklen_t(MemoryLayout.size(ofValue: a))
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(f, $0, &n) } }
        endpoint = "http://127.0.0.1:\(UInt16(bigEndian: a.sin_port))"
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            while true {
                let c = accept(f, nil, nil); if c < 0 { break }
                serve(c); close(c)
            }
        }
    }
    func stop() { shutdown(fd, SHUT_RDWR); close(fd); group.wait() }
    func requests() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
    func seat(_ name: String = "primary", cap: Int? = 37, model: String = "test-model") -> [String: Any] {
        var c: [String: Any] = ["seconds": 20]; if let cap { c["tokens"] = cap }
        return u6aSeat(name, "ollama", extra: ["endpoint": endpoint, "model": model, "cap": c,
            "price": ["input_per_mtok": 2.0, "output_per_mtok": 5.0]])
    }
    private func serve(_ c: Int32) {
        var noPipe: Int32 = 1; guard setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, 4) == 0 else { return }
        var t = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout.size(ofValue: t)))
        var header = Data(), byte: UInt8 = 0
        while read(c, &byte, 1) == 1 { header.append(byte); if header.suffix(4) == Data("\r\n\r\n".utf8) { break } }
        let h = String(decoding: header, as: UTF8.self)
        let count = h.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        var body = Data()
        for _ in 0..<count { guard read(c, &byte, 1) == 1 else { return }; body.append(byte) }
        let chat = h.hasPrefix("POST /api/chat ")
        let json = (try? brokerJSON(body)) ?? [:]
        if chat { lock.lock(); bodies.append(json); lock.unlock() }
        let model = json["model"] as? String ?? ""
        let failed = chat && (fail || model == "fail")
        var payload: [String: Any] = chat ? ["message": ["content": "u6a answer"], "done": true] :
            ["models": ["test-model", "reported", "unreported", "fail"].map { ["name": $0, "model": $0] }]
        if chat && usage && model != "unreported" { payload["prompt_eval_count"] = 7; payload["eval_count"] = 3 }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var reply = Data("HTTP/1.1 \(failed ? "500 Error" : "200 OK")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        reply.append(data)
        reply.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(c, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n <= 0 { break }; offset += n
            }
        }
    }
}

final class U6cResults: @unchecked Sendable {
    let lock = NSLock()
    var replies: [[String: Any]] = []
    var errors: [String] = []
    func append(_ operation: () throws -> [String: Any]) {
        do { let r = try operation(); lock.lock(); replies.append(r); lock.unlock() }
        catch { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
    }
}
