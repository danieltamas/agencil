import Foundation
import Testing

// Stdio framing is one JSON object per line, including recoverable protocol errors.
final class BrokerMCP {
    let child: BrokerProcess
    private var offset: UInt64 = 0
    init(_ home: BrokerHome) throws { child = try BrokerProcess(["mcp", "--caller", "maya"], home: home.url) }
    func send(_ object: [String: Any]) throws { try raw(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
    func raw(_ line: String) throws { try child.input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
    func read() throws -> [String: Any] {
        var line = Data()
        try brokerPoll {
            let bytes = try self.child.outputSnapshot().dropFirst(Int(self.offset))
            let buffer = Data(bytes)
            if let end = buffer.firstIndex(of: 10) {
                line = buffer.prefix(upTo: end)
                self.offset += UInt64(end + 1)
                return true
            }
            return false
        }
        return try brokerJSON(line)
    }
    func call(_ method: String, _ params: Any = [String: String]()) throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let response = try read()
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? Int == 1)
        return response
    }
    func initialize(_ version: String) throws -> [String: Any] {
        let response = try call("initialize", ["protocolVersion": version, "capabilities": [:],
                                               "clientInfo": ["name": "acceptance", "version": "1"]] as [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return result
    }
}

@Suite struct BrokerAcceptanceTestsMCP {
    @Test(arguments: ["2025-06-18", "2025-03-26"])
    func handshakeSchemasAndEveryToolRefusesByDefault(version: String) throws {
        let home = try BrokerHome(), server = try BrokerMCP(home)
        #expect(try server.initialize(version)["protocolVersion"] as? String == version)
        let response = try server.call("tools/list")
        let result = try #require(response["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let arguments: [String: [String: Any]] = [
            "list_targets": [:], "ask": ["target": "reviewer", "question": "Review"],
            "ask_result": ["thread": "t1"],
            "wake_council": ["council": "review", "brief": "Review", "change_kind": "docs"],
            "sitting_status": ["sitting": "s1"], "sitting_verdict": ["sitting": "s1"], "stop": ["id": "t1"]]
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(arguments.keys))
        #expect(tools.count == 7)
        for tool in tools {
            #expect(tool["inputSchema"] as? [String: Any] != nil)
            #expect((tool["outputSchema"] != nil) == (version == "2025-06-18"))
            let name = try #require(tool["name"] as? String)
            let call = try server.call("tools/call", ["name": name, "arguments": arguments[name]!] as [String: Any])
            let output = try #require(call["result"] as? [String: Any])
            #expect(output["isError"] as? Bool == true)
            let blocks = try #require(output["content"] as? [[String: Any]])
            let text = try #require(blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String)
            #expect(text.contains("Agent access is off in Agencil Settings"))
            let envelope = try brokerJSON(Data(text.utf8))
            #expect(envelope["api"] as? Int == 1)
            #expect(envelope["source"] as? String == "agencil")
            #expect(envelope["generated_at"] as? String != nil)
            #expect(envelope["data_note"] as? String != nil)
            #expect((envelope["data"] as? [String: Any])?["state"] as? String == "refused")
            if version == "2025-06-18" {
                let structured = try #require(output["structuredContent"] as? [String: Any])
                #expect(NSDictionary(dictionary: structured).isEqual(to: envelope))
            } else { #expect(output["structuredContent"] == nil) }
        }
    }

    @Test func unknownProtocolNegotiatesSupportedVersion() throws {
        let home = try BrokerHome(), server = try BrokerMCP(home)
        let negotiated = try server.initialize("2099-01-01")["protocolVersion"] as? String
        #expect(["2025-06-18", "2025-03-26"].contains(negotiated ?? ""))
    }

    @Test func protocolErrorsAndOversizedLineDoNotKillServer() throws {
        let home = try BrokerHome(), server = try BrokerMCP(home)
        _ = try server.initialize("2025-06-18")
        let unknown = try server.call("missing")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        try server.raw("{invalid")
        let malformed = try server.read()
        #expect((malformed["error"] as? [String: Any])?["code"] as? Int == -32700)
        let invalid = try server.call("tools/call", ["name": 17])
        #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32602)
        try server.raw("{\"padding\":\"" + String(repeating: "x", count: 1_048_577) + "\"}")
        #expect(try server.read()["error"] as? [String: Any] != nil)
        #expect(try server.call("tools/list")["result"] != nil)
    }

    @Test(arguments: ["off", "unknown"])
    func nonOnAgentAccessStillRefuses(value: String) throws {
        let home = try BrokerHome()
        try Data("{\"agent_access\":\"\(value)\"}".utf8).write(to: home.url.appendingPathComponent("config.json"))
        let server = try BrokerMCP(home)
        _ = try server.initialize("2025-06-18")
        let response = try server.call("tools/call", ["name": "list_targets", "arguments": [:]] as [String: Any])
        #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
    }
}
