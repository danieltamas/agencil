import Foundation

/// The seven tools of the Agencil MCP server (docs/AGENT-API.md), with JSON Schema inputs and one envelope
/// output schema. They live in code, not resource files: the installed CLI is a single file with no bundle beside it.
enum MCPSchemas {
    struct Tool {
        let name: String
        let title: String
        let brokerOp: String
        let input: [String: Any]
    }

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static var text: [String: Any] { ["type": "string"] }
    private static func bounded(_ limit: Int) -> [String: Any] { ["type": "string", "maxLength": limit] }
    private static var wait: [String: Any] { ["type": "integer", "minimum": 0, "maximum": 600] }

    static var tools: [Tool] { [
        Tool(name: "list_targets", title: "List the seats and councils this caller may reach", brokerOp: "list_targets",
             input: object([:])),
        Tool(name: "ask", title: "Ask one seat a question", brokerOp: "ask",
             input: object(["target": bounded(64), "question": bounded(65_536),
                            "files": ["type": "array", "items": text], "thread": bounded(64), "wait_seconds": wait],
                           required: ["target", "question"])),
        Tool(name: "ask_result", title: "Fetch the answer of an earlier ask", brokerOp: "result",
             input: object(["thread": bounded(64), "wait_seconds": wait, "full": ["type": "boolean"],
                            "offset": ["type": "integer", "minimum": 0]], required: ["thread"])),
        Tool(name: "wake_council", title: "Start a sitting of a council", brokerOp: "wake",
             input: object(["council": bounded(64), "brief": bounded(65_536), "repo": text, "diff": text,
                            "change_kind": bounded(64), "wait_seconds": wait],
                           required: ["council", "brief", "change_kind"])),
        Tool(name: "sitting_status", title: "Seats, rounds and claims of a sitting so far", brokerOp: "status",
             input: object(["sitting": bounded(64)], required: ["sitting"])),
        Tool(name: "sitting_verdict", title: "The verdict of a sitting", brokerOp: "result",
             input: object(["sitting": bounded(64), "wait_seconds": wait], required: ["sitting"])),
        Tool(name: "stop", title: "Stop a thread or sitting", brokerOp: "stop",
             input: object(["id": bounded(64)], required: ["id"])),
    ] }

    static var output: [String: Any] { object([
        "api": ["type": "integer"], "source": text, "generated_at": text, "data_note": text,
        "data": ["type": "object"],
    ], required: ["api", "source", "generated_at", "data_note", "data"]).merging(["additionalProperties": true]) { _, new in new } }

    /// `tools/list` entries; the output schema exists only from protocol 2025-06-18.
    static func listing(protocolVersion: String) -> [[String: Any]] {
        tools.map { tool in
            var entry: [String: Any] = ["name": tool.name, "title": tool.title, "description": tool.title,
                                        "inputSchema": tool.input]
            if protocolVersion == "2025-06-18" { entry["outputSchema"] = output }
            return entry
        }
    }
}
