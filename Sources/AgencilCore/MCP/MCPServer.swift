import Darwin
import Foundation

/// JSON-RPC 2.0 over stdio, one object per line. A thin client of the broker: it never runs a seat itself.
public struct MCPServer {
    private static let supported = ["2025-06-18", "2025-03-26"]
    static let refusal = "refused: Agent access is off in Agencil Settings"

    private let home: AgencilHome
    private let caller: String

    public init(home: AgencilHome, caller: String) {
        self.home = home
        self.caller = caller
    }

    /// Serves until stdin closes.
    public func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let reader = UnixSocket.Reader(descriptor: 0)
        var negotiated = Self.supported[0]
        while true {
            switch reader.next() {
            case .end: return 0
            case .tooLong: respond(error: -32600, "request line exceeds 1 MB", id: NSNull())
            case .line(let data):
                guard !data.isEmpty else { continue }
                handle(data, negotiated: &negotiated)
            }
        }
    }

    private func handle(_ data: Data, negotiated: inout String) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return respond(error: -32700, "parse error", id: NSNull())
        }
        guard let message = parsed as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            return respond(error: -32600, "invalid request", id: Self.validID((parsed as? [String: Any])?["id"]) ?? NSNull())
        }
        // No id: a notification, which never gets a reply.
        guard let rawID = message["id"] else { return }
        guard let id = Self.validID(rawID) else { return respond(error: -32600, "id must be a string, a number or null", id: NSNull()) }
        guard message["params"] == nil || message["params"] is [String: Any] else {
            return respond(error: -32602, "params must be an object", id: id)
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            negotiated = Self.supported.contains(requested) ? requested : Self.supported[0]
            respond(result: ["protocolVersion": negotiated, "capabilities": ["tools": ["listChanged": false]],
                             "serverInfo": ["name": "agencil", "version": AgencilVersion.current()]], id: id)
        case "ping":
            respond(result: [:], id: id)
        case "tools/list":
            respond(result: ["tools": MCPSchemas.listing(protocolVersion: negotiated)], id: id)
        case "tools/call":
            guard let name = params["name"] as? String, let tool = MCPSchemas.tools.first(where: { $0.name == name }) else {
                return respond(error: -32602, "invalid params: name must be one of the seven tools", id: id)
            }
            guard let arguments = (params["arguments"] ?? [String: Any]()) as? [String: Any] else {
                return respond(error: -32602, "invalid params: arguments must be an object", id: id)
            }
            if let problem = MCPBounds.violation(arguments, schema: tool.input) {
                return respond(error: -32602, "invalid params: \(problem)", id: id)
            }
            respond(result: call(tool, arguments, structured: negotiated == "2025-06-18"), id: id)
        default:
            respond(error: -32601, "method not found: \(method)", id: id)
        }
    }

    /// Off by default: anything but an explicit "on" in config.json refuses, and so does an unreadable config.
    private func call(_ tool: MCPSchemas.Tool, _ arguments: [String: Any], structured: Bool) -> [String: Any] {
        let on = (try? ConfigStore(directory: home.directory).read().values["agent_access"]) == "on"
        guard on else { return toolResult(["state": "refused", "reason": Self.refusal.replacingOccurrences(of: "refused: ", with: "")], error: true, structured: structured) }
        var request = arguments
        request["op"] = tool.brokerOp
        request["caller"] = caller
        if let capability = ProcessInfo.processInfo.environment["AGENCIL_CAP"], !capability.isEmpty { request["cap"] = capability }
        if let thread = arguments["thread"] ?? arguments["sitting"] { request["id"] = thread }
        if tool.brokerOp == "ask" || tool.brokerOp == "wake", let project = ProjectLabel.label(cwd: FileManager.default.currentDirectoryPath) {
            request["project"] = project
        }
        do {
            let reply = try BrokerClient(home: home).send(request)
            if reply["ok"] as? Bool == true {
                return toolResult((reply["data"] as? [String: Any]) ?? reply.filter { $0.key != "ok" }, error: false, structured: structured)
            }
            let refused = reply["exit"] as? Int == 3
            return toolResult(["state": refused ? "refused" : "failed", "reason": reply["error"] as? String ?? "request failed"],
                              error: true, structured: structured)
        } catch let failure as BrokerClient.Failure {
            return toolResult(["state": "refused", "reason": failure.message], error: true, structured: structured)
        } catch {
            return toolResult(["state": "failed", "reason": error.localizedDescription], error: true, structured: structured)
        }
    }

    /// JSON-RPC ids are strings, numbers or null; an object, array or boolean is not one.
    private static func validID(_ id: Any?) -> Any? {
        switch id {
        case is String, is NSNull: return id
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number
        default: return nil
        }
    }

    private func toolResult(_ data: [String: Any], error: Bool, structured: Bool) -> [String: Any] {
        let envelope = Envelope.make(data: MCPBounds.bounded(data), note: Broker.note)
        var result: [String: Any] = ["content": [["type": "text", "text": Envelope.text(envelope)]], "isError": error]
        if structured { result["structuredContent"] = envelope }
        return result
    }

    private func respond(result: [String: Any], id: Any) {
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respond(error code: Int, _ message: String, id: Any) {
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func emit(_ object: [String: Any]) {
        UnixSocket.write(1, line: UnixSocket.json(object))
    }
}
