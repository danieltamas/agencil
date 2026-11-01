import Darwin
import Foundation
import Testing

func u25Seats() -> [[String: Any]] {
    zip(zip(["a", "b", "c", "d"], ["codex", "claude", "hermes", "opencode"]),
        ["harbor", "lumen", "cedar", "maple"]).map { pair, vendor in
        u6aSeat(pair.0, pair.1, extra: ["vendor": vendor, "model": "harbor-model",
            "cap": ["seconds": 10, "tokens": 37]])
    }
}

// Real broker, Unix socket, ledger, adapter confinement and per-test stub harnesses.
final class U25Rig {
    let packet: U6dRig
    var base: U6aRig { packet.base }
    var home: BrokerHome { packet.home }
    let control: URL

    init() throws {
        packet = try U6dRig()
        control = packet.home.url.appendingPathComponent("u25-control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        base.broker?.kill(); _ = try base.broker?.finish()
        for kind in ["codex", "claude", "opencode", "hermes"] {
            let url = base.bin.appendingPathComponent(kind)
            try Data(contentsOf: brokerFixture("u25-seat.sh")).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let wrapper = base.bin.appendingPathComponent("u25-sandbox")
        try Data(contentsOf: brokerFixture("u7a-sandbox.sh")).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        try put("opencode.models", "harbor-model\n")
        for kind in ["codex", "claude", "opencode", "hermes"] {
            try put(kind + ".ask", "OK")
        }
        for seat in ["a", "b", "c", "d"] {
            try put(seat + ".mode", "answer")
            for round in ["blind", "rebuttal", "challenge"] { try reply(seat, round: round) }
            try put(seat + ".synthesis", "{\"summary\":\"harbor summary\"}")
        }
        try configure()
        base.broker = try home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": base.bin.path,
            "HOME": packet.fakeHome.path, "STUB_DIR": control.path,
            "STUB_CLI": try brokerBinary().path, "AGENCIL_TEST_SANDBOX_EXEC": wrapper.path])
    }

    deinit {
        base.broker?.kill()
        for file in observations(suffix: "pid") {
            if let value = try? text(file), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                brokerGroupCleanup(pid)
                if brokerAlive(pid) { Darwin.kill(pid, SIGKILL) }
            }
        }
    }

    func configure(seats: [[String: Any]] = u25Seats(), council: [String: Any] = u7aCouncil(),
                   routes: [[String: Any]]? = nil, raw: [String: String] = [:]) throws {
        try base.config(seats: seats, routes: routes ?? [u6aRoute("panel"), u6aRoute("a")],
            raw: ["councils": try u6aText([council]), "agent_access": "on"].merging(raw) { _, b in b })
    }
    func put(_ name: String, _ value: String = "") throws {
        try packet.put(control.appendingPathComponent(name), value)
    }
    func mode(_ key: String, _ value: String) throws { try put(key + ".mode", value) }
    func reply(_ seat: String, round: String = "blind", answer: String? = nil) throws {
        try put(seat + "." + round, try answer ?? u7aAnswer())
    }
    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func invocations() -> String { (try? text(control.appendingPathComponent("invocations"))) ?? "" }
    func observations(_ seat: String? = nil, _ round: String? = nil, suffix: String = "prompt") -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: control, includingPropertiesForKeys: nil)) ?? [])
            .filter {
                let p = $0.lastPathComponent.split(separator: ".").map(String.init)
                return p.count >= 5 && p[0] == "record" && p.last == suffix &&
                    (seat == nil || p[2] == seat) && (round == nil || p[3] == round)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func observation(_ seat: String, _ round: String = "probe", suffix: String) throws -> String {
        try text(#require(observations(seat, round, suffix: suffix).first))
    }
    func request(_ op: String, _ extra: [String: Any] = [:], caller: String = "owner") throws -> [String: Any] {
        try home.request(["op": op, "caller": caller].merging(extra) { _, b in b })
    }
    func data(_ reply: [String: Any]) throws -> [String: Any] { try base.data(reply) }
    func rows(_ reply: [String: Any], key: String = "seats") throws -> [[String: Any]] {
        try #require(data(reply)[key] as? [[String: Any]])
    }
    func preflight(_ seats: [String]? = nil, probe: Bool = false,
                   caller: String = "owner") throws -> [[String: Any]] {
        var extra: [String: Any] = ["probe": probe]
        if let seats { extra["seats"] = seats }
        return try rows(request("preflight", extra, caller: caller))
    }
    func seat(_ rows: [[String: Any]], _ name: String) throws -> [String: Any] {
        try #require(rows.first { $0["name"] as? String == name })
    }
    func panelSeats() throws -> [[String: Any]] {
        let panel = try data(request("panel"))
        let seats = try #require(panel["seats"] as? [String: Any])
        return try #require(seats["items"] as? [[String: Any]])
    }
    func failure(_ reply: [String: Any], exit: Int, contains: [String]) throws {
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == exit)
        let error = try #require(reply["error"] as? String)
        for fragment in contains { #expect(error.contains(fragment)) }
    }
    func sql(_ query: String) throws -> String { try packet.budget.sql(query) }
    func ledger(_ query: String) throws -> [[String]] { try u24Rows(home.url, query) }
    func noWork() throws {
        for table in ["briefs", "snapshots", "runs", "sittings", "seat_runs"] {
            #expect(try sql("SELECT count(*) FROM \(table);") == "0\n")
        }
        #expect(observations(nil, "blind").isEmpty)
        #expect(observations(nil, "synthesis").isEmpty)
    }
    func wake() throws -> [String: Any] {
        try request("wake", ["council": "panel", "question": "inspect harbor",
            "change_kind": "design", "author_vendor": "google", "wait_seconds": 10])
    }
    func verdict(_ reply: [String: Any]) throws -> [String: Any] {
        let d = try data(reply)
        if let v = d["verdict"] as? [String: Any] { return v }
        return d
    }
    func passed() throws -> [String: Any] {
        let v = try verdict(wake())
        #expect(v["verdict"] as? String == "PASS")
        #expect(v["state"] as? String == "done")
        return v
    }
    func cli(_ args: [String], exit: Int32) throws -> (String, String) {
        let p = try BrokerProcess(args, home: home.url)
        let (code, out, err) = try p.finish(20)
        #expect(code == exit)
        return (out, err)
    }
    func cliRows(_ args: [String], exit: Int32) throws -> [[String: Any]] {
        let (out, _) = try cli(args + ["--json"], exit: exit)
        let data = try #require(brokerJSON(Data(out.utf8))["data"] as? [String: Any])
        return try #require(data["seats"] as? [[String: Any]])
    }
}
