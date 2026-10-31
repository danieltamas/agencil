import Darwin
import Foundation
import Testing

// Composition keeps the independent U6a acceptance fixtures unchanged.
final class U6bRig {
    let base: U6aRig
    var home: BrokerHome { base.home }
    var record: String { base.record.path }
    init(_ plans: [String: String] = [:], limit: Int = 2,
         callers: [String] = ["owner", "a", "b", "c"], fault: String? = nil) throws {
        base = try U6aRig(["codex", "claude", "hermes"])
        base.broker?.kill()
        _ = try base.broker?.finish()
        for kind in ["codex", "claude", "hermes"] {
            let path = base.bin.appendingPathComponent(kind)
            try Data(contentsOf: brokerFixture("u6b-seat.sh")).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        try base.config(seats: [u6aSeat("a", "codex"), u6aSeat("b", "claude"), u6aSeat("c", "hermes"), u6aSeat("d", "codex")],
                        routes: ["a", "b", "c", "d"].map {
                            ["callers": callers, "target": $0, "hop_limit": limit, "fallbacks": []] as [String: Any]
                        }, raw: ["agent_access": "on"])
        var env = ["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": base.bin.path,
                   "STUB_CLI": try brokerBinary().path, "STUB_RECORD": record]
        for kind in ["codex", "claude", "hermes"] { env["STUB_PLAN_" + kind] = plans[kind] ?? "leaf:" }
        if let fault { env["AGENCIL_TEST_FAIL_ANCESTRY"] = fault }
        base.broker = try home.serve(env)
    }
    deinit {
        if let text = try? read("pids") {
            for pid in text.split(separator: "\n").compactMap({ Int32($0) }) { brokerGroupCleanup(pid) }
        }
        if let text = try? read("detached.pid"), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), brokerAlive(pid) {
            Darwin.kill(pid, SIGKILL)
        }
    }
    func read(_ suffix: String) throws -> String {
        try String(contentsOfFile: record + "." + suffix, encoding: .utf8)
    }
    func data(_ kind: String) throws -> [String: Any] {
        let envelope = try brokerJSON(Data(read(kind + ".out").utf8))
        return try #require(envelope["data"] as? [String: Any])
    }
    func root(_ seat: String = "a") throws -> [String: Any] {
        let (code, out, _) = try home.cli(["ask", seat, "root", "--wait", "10", "--json"])
        #expect(code == 0)
        return try #require(brokerJSON(Data(out.utf8))["data"] as? [String: Any])
    }
    func chain(_ data: [String: Any], _ seats: [String]) {
        #expect(data["chain"] as? [String] == seats)
        #expect(data["state"] as? String == "answered")
    }
    func refusal(_ kind: String, _ reason: String) throws {
        #expect(try read(kind + ".exit") == "3")
        #expect(try read(kind + ".err").trimmingCharacters(in: .whitespacesAndNewlines) == "agencil: " + reason)
    }
    func sql(_ query: String) throws -> String {
        let p = try BrokerProcess(["-readonly", home.url.appendingPathComponent("agencil.sqlite").path, query],
                                  home: home.url, executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
        let (code, out, _) = try p.finish()
        #expect(code == 0)
        return out
    }
}
