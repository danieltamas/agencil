import Foundation
import Testing
import AgencilCore

// U22's committed-WAL copy pattern, composed with U6's real executable rig.
final class U23Rig {
    let base: U6aRig
    let loop: LearnLoop
    var home: BrokerHome { base.home }

    init(_ fixture: U12Fixture, answer: String = "ENDORSE\nlooks sound", fail: Bool = false) throws {
        base = try U6aRig(["claude"])
        base.broker?.kill()
        _ = try base.broker?.finish()
        let database = base.home.url.appendingPathComponent("agencil.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
        try fixture.sql("VACUUM INTO ?", [database.path])
        try fixture.bytes().write(to: base.home.url.appendingPathComponent("config.json"))
        let store = ConfigStore(directory: base.home.url)
        let values = try store.read().values
        let seatText = try #require(values["seats"])
        var seats = try #require(JSONSerialization.jsonObject(with: Data(seatText.utf8)) as? [[String: Any]])
        for index in seats.indices {
            seats[index]["harness"] = "claude"
            seats[index]["hardening"] = []
            seats[index]["cap"] = ["seconds": 10, "tokens": 1000]
        }
        let encodedSeats = try u6aText(seats)
        let routes = try u6aText(seats.compactMap { $0["name"] as? String }.map { u6aRoute($0) })
        _ = try store.update { $0["seats"] = encodedSeats; $0["routes"] = routes }
        let quoted = "'" + answer.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = try String(contentsOf: brokerFixture("u6a-seat.sh"), encoding: .utf8)
            .replacingOccurrences(of: "answer='u6a answer'", with: "answer=" + quoted)
            .replacingOccurrences(of: "input=$(/bin/cat)",
                with: "input=$(/bin/cat)\nprintf '%s' \"$input\" > \"$STUB_RECORD.prompt\"")
        try script.write(to: base.bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        loop = LearnLoop(ledger: try Ledger(directory: base.home.url), directory: base.home.url)
        base.broker = try base.home.serve(["AGENCIL_TEST_SEAMS": "1",
            "AGENCIL_PATH_PREFIX": base.bin.path, "STUB_RECORD": base.record.path,
            "STUB_MODE": fail ? "fail" : "answer"])
    }

    func review(_ id: String, caller: String = "owner") throws -> [String: Any] {
        try home.request(["op": "learn", "action": "review", "id": id,
                          "caller": caller, "wait_seconds": 5])
    }
    func data(_ reply: [String: Any]) throws -> [String: Any] { try base.data(reply) }
    func row(_ id: String) throws -> [String: Any] {
        let reply = try data(home.request(["op": "proposals", "caller": "owner"]))
        return try #require((reply["proposals"] as? [[String: Any]])?.first { $0["id"] as? String == id })
    }
    func unchanged(_ id: String) throws {
        let row = try row(id)
        #expect(row["status"] as? String == "proposed")
        #expect(row["reviewer"] is NSNull)
        #expect(row["verdict"] is NSNull)
        #expect(row["note"] is NSNull)
        #expect(try loop.versions().isEmpty)
    }
    func refused(_ reply: [String: Any], exit: Int) throws {
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == exit)
        #expect(reply["data"] == nil)
        #expect(!(try #require(reply["error"] as? String)).isEmpty)
    }
}
