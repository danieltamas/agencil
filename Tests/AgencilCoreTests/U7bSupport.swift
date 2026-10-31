import Foundation
import Testing

// Only public broker operations, real git, and the spec's public ledger tables.
final class U7bRig {
    let council: U7aRig
    var home: BrokerHome { council.home }
    var repo: URL { council.packet.repo }
    init() throws {
        council = try U7aRig()
        try council.packet.repository()
        _ = try git(["reset", "--hard", "HEAD"])
        let gh = council.base.bin.appendingPathComponent("gh")
        try Data(contentsOf: brokerFixture("u7b-gh.sh")).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        try council.put("gh.json", "[]")
        try restart()
    }
    func restart() throws {
        council.base.broker?.kill(); _ = try council.base.broker?.finish()
        council.base.broker = try home.serve([
            "TZ": "UTC", "AGENCIL_TEST_SEAMS": "1", "AGENCIL_TRIGGER_SECONDS": "86400",
            "AGENCIL_PATH_PREFIX": council.base.bin.path, "HOME": council.packet.fakeHome.path,
            "STUB_DIR": council.control.path, "STUB_CLI": try brokerBinary().path,
            "STUB_LEDGER": home.url.appendingPathComponent("agencil.sqlite").path,
            "AGENCIL_TEST_SANDBOX_EXEC": council.base.bin.appendingPathComponent("u7a-sandbox").path])
    }
    func trigger(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["name": "watch", "council": "panel", "repo": repo.path, "paths": ["src/**"],
         "debounce_seconds": 0].merging(extra) { _, b in b }
    }
    func configure(_ triggers: Any, allowed: Bool = true) throws {
        try council.configure(routes: [u6aRoute("panel", callers: allowed ? ["owner", "trigger"] : ["owner"])],
                              raw: ["triggers": try u6aText(triggers)])
    }
    func only(_ kind: String, _ value: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var t = trigger(extra); t.removeValue(forKey: "paths"); t[kind] = value; return t
    }
    @discardableResult func git(_ args: [String]) throws -> String {
        let p = try BrokerProcess(["-C", repo.path] + args, home: home.url,
                                  executable: URL(fileURLWithPath: "/usr/bin/git"))
        let (code, out, _) = try p.finish(); #expect(code == 0)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func commit(_ path: String = "src/main.swift", _ text: String = UUID().uuidString) throws -> String {
        try council.packet.put(repo.appendingPathComponent(path), text)
        try git(["add", "."])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "change"])
        return try git(["rev-parse", "HEAD"])
    }
    func tick(_ time: String = "2030-01-01T12:00:00Z") throws -> [String: Any] {
        try council.base.data(home.request(["op": "tick", "now": time]))
    }
    func rows(_ reply: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(reply[key] as? [[String: Any]])
    }
    func idle(_ reply: [String: Any], reason: String? = nil) throws {
        #expect(try rows(reply, "fired").isEmpty)
        let deferred = try rows(reply, "deferred")
        if let reason {
            #expect(deferred.count == 1)
            #expect(deferred.first?["trigger"] as? String == "watch")
            #expect(deferred.first?["reason"] as? String == reason)
        } else { #expect(deferred.isEmpty) }
    }
    @discardableResult func fired(_ reply: [String: Any], key: String, wait: Bool = true) throws -> String {
        let rows = try rows(reply, "fired"); #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["trigger"] as? String == "watch"); #expect(row["council"] as? String == "panel")
        #expect(row["key"] as? String == key)
        let id = try #require(row["sitting"] as? String)
        #expect(id.hasPrefix("sit_"))
        if wait { _ = try council.cli(["result", id, "--wait", "15"], exit: 0) }
        #expect(try council.sql("SELECT count(*) FROM trigger_fires WHERE trigger='watch' AND key='\(key)' AND sitting='\(id)' AND outcome='fired';") == "1\n")
        #expect(try Double(value("last_fire")) != nil)
        return id
    }
    func state() throws -> String {
        try council.sql("SELECT trigger,key,value FROM trigger_state ORDER BY trigger,key;")
    }
    func value(_ key: String) throws -> String {
        try council.sql("SELECT value FROM trigger_state WHERE trigger='watch' AND key='\(key)';")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func prs(_ rows: [[String: Any]]) throws { try council.put("gh.json", u6aText(rows)) }
    func pr(_ n: Int, _ sha: String) -> [String: Any] { ["number": n, "headRefOid": sha] }
}
