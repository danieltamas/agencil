import Darwin
import Foundation
import Testing

func u7aCouncil(_ extra: [String: Any] = [:]) -> [String: Any] {
    ["name": "panel", "seats": ["a", "b", "c"], "deadline_seconds": 15,
     "rounds": ["rebuttal": false]].merging(extra) { _, b in b }
}
func u7aSeats() -> [[String: Any]] {
    zip(["a", "b", "c", "d"], ["codex", "claude", "hermes", "opencode"]).map {
        u6aSeat($0.0, $0.1, extra: ["cap": ["seconds": 10, "tokens": 37]])
    }
}
func u7aClaim(_ severity: String = "p1", evidence: String = "CLAIM_MARKER") -> [String: Any] {
    ["id": "local", "kind": "defect", "severity": severity, "confidence": 0.9,
     "file": "src/main.swift", "line": 1, "evidence": evidence]
}
func u7aAnswer(_ vote: String = "approve", claims: [[String: Any]] = [],
               assessments: [[String: Any]] = []) throws -> String {
    try u6aText(["vote": vote, "claims": claims, "assessments": assessments, "notes": "PRIVATE_NOTES_MARKER"])
}
func u7aAssessment(_ stance: String, _ claim: String = "AG-1-1") -> [String: Any] {
    ["claim": claim, "stance": stance, "why": "EVIDENCE_" + stance]
}

// Composition over U6d retains its fake HOME, real git and real confinement.
// The wrapper grants only STUB_DIR; records survive copy cleanup.
final class U7aRig {
    let packet: U6dRig
    var base: U6aRig { packet.base }
    var home: BrokerHome { packet.home }
    let control: URL
    init() throws {
        packet = try U6dRig()
        control = packet.home.url.appendingPathComponent("u7a-control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        base.broker?.kill(); _ = try base.broker?.finish()
        for kind in ["codex", "claude", "hermes", "opencode"] {
            let url = base.bin.appendingPathComponent(kind)
            try Data(contentsOf: brokerFixture("u7a-seat.sh")).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let wrapper = base.bin.appendingPathComponent("u7a-sandbox")
        try Data(contentsOf: brokerFixture("u7a-sandbox.sh")).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        try configure()
        for seat in ["a", "b", "c", "d"] {
            for round in ["blind", "rebuttal", "challenge"] { try reply(seat, round, u7aAnswer()) }
            try reply(seat, "synthesis", "{\"summary\":\"SUMMARY_MARKER\"}")
        }
        base.broker = try home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": base.bin.path,
            "HOME": packet.fakeHome.path, "STUB_DIR": control.path,
            "STUB_LEDGER": home.url.appendingPathComponent("agencil.sqlite").path,
            "STUB_CLI": try brokerBinary().path, "AGENCIL_TEST_SANDBOX_EXEC": wrapper.path])
    }
    deinit {
        base.broker?.kill()
        for url in records().filter({ $0.pathExtension == "pid" || $0.lastPathComponent.hasSuffix("child-pid") }) {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                brokerGroupCleanup(pid)
                if brokerAlive(pid) { Darwin.kill(pid, SIGKILL) }
            }
        }
    }
    func configure(_ council: [String: Any] = u7aCouncil(), seats: [[String: Any]] = u7aSeats(),
                   routes: [[String: Any]]? = nil, raw: [String: String] = [:], councils: Any? = nil) throws {
        try base.config(seats: seats, routes: routes ?? [u6aRoute("panel"), u6aRoute("a")],
            raw: ["councils": try u6aText(councils ?? [council]), "agent_access": "on"]
                .merging(raw) { _, b in b })
    }
    func put(_ name: String, _ text: String = "") throws { try packet.put(control.appendingPathComponent(name), text) }
    func reply(_ seat: String, _ answer: String) throws {
        try reply(seat, "blind", answer)
    }
    func reply(_ seat: String, _ round: String, _ answer: String) throws {
        try put(seat + "." + round, answer)
    }
    func records() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: control, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("record.") }
    }
    func observations(_ seat: String? = nil, _ round: String? = nil, suffix: String = "prompt") -> [URL] {
        records().filter {
            let parts = $0.lastPathComponent.split(separator: ".").map(String.init)
            return parts.count >= 5 && (seat == nil || parts[2] == seat) &&
                (round == nil || parts[3] == round) && parts.last == suffix
        }.sorted { Int($0.lastPathComponent.split(separator: ".")[1])! < Int($1.lastPathComponent.split(separator: ".")[1])! }
    }
    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func prompt(_ seat: String, _ round: String = "blind") throws -> String {
        try text(#require(observations(seat, round).first))
    }
    func sql(_ query: String) throws -> String { try packet.budget.sql(query) }
    func cli(_ args: [String], exit: Int32) throws -> [String: Any] {
        let process = try BrokerProcess(args + ["--json"], home: home.url)
        let (code, out, _) = try process.finish(20)
        #expect(code == exit)
        let envelope = try brokerJSON(Data(out.utf8))
        #expect(envelope["ok"] as? Bool == true)
        return try #require(envelope["data"] as? [String: Any])
    }
    func wake(_ extra: [String] = [], exit: Int32 = 0,
              brief: String = "change_kind: design\nquestion: inspect packet\nauthor_vendor: google\n") throws -> [String: Any] {
        try put("brief", brief)
        return try cli(["wake", "panel", "--brief", control.appendingPathComponent("brief").path,
                        "--wait", "15"] + extra, exit: exit)
    }
    func verdict(_ reply: [String: Any]) throws -> [String: Any] {
        if let verdict = reply["verdict"] as? [String: Any] { return verdict }
        return reply
    }
    @discardableResult
    func decided(_ expected: String, _ reason: String? = nil, extra: [String] = [],
                 brief: String = "change_kind: design\nquestion: inspect packet\nauthor_vendor: google\n") throws -> [String: Any] {
        let v = try verdict(wake(extra, exit: expected == "PASS" ? 0 : expected == "BLOCK" ? 1 : 2, brief: brief))
        #expect(v["verdict"] as? String == expected)
        #expect(v["state"] as? String == "done")
        if let reason { #expect((v["reasons"] as? [String])?.first?.hasPrefix(reason) == true) }
        return v
    }
    func flags(_ v: [String: Any]) throws -> [String] { try #require(v["independence"] as? [String]) }
    func rows(_ v: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(v[key] as? [[String: Any]])
    }
    func vote(_ v: [String: Any], _ name: String) throws -> [String: Any] {
        try #require(rows(v, "votes").first { $0["seat"] as? String == name })
    }
    func noRuns() throws {
        #expect(observations().isEmpty)
        #expect(try sql("SELECT count(*) FROM runs;") == "0\n")
    }
    func stoppedPIDs(_ seat: String) throws {
        let files = observations(seat, suffix: "pid") + observations(seat, suffix: "child-pid")
        #expect(!files.isEmpty)
        for url in files {
            let pid = try #require(Int32(text(url).trimmingCharacters(in: .whitespacesAndNewlines)))
            try brokerPoll(15) { !brokerAlive(pid) }
        }
    }
}
