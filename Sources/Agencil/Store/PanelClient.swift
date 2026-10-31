import AgencilCore
import Foundation

/// The panel's side of the broker socket. Each call runs off the main actor; the socket round trip blocks.
struct PanelClient: Sendable {
    struct Refused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let client: BrokerClient

    init(home: AgencilHome) { client = BrokerClient(home: home) }

    func read() async throws -> PanelData {
        let reply = try await send(["op": "panel"])
        guard let data = reply["data"] as? [String: Any] else { throw Refused(message: "the panel read had no data") }
        return try PanelData(json: data)
    }

    func stop(_ id: String) async throws {
        _ = try await send(["op": "stop", "id": id])
    }

    /// One op, owner caller; the reply's `data` object.
    func call(_ op: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        let reply = try await send(["op": op, "caller": "owner"].merging(extra) { _, new in new })
        return reply["data"] as? [String: Any] ?? [:]
    }

    private func send(_ request: [String: Any]) async throws -> [String: Any] {
        let client = client
        let payload = JSONBox(value: request)
        let reply = try await Task.detached {
            let reply = try client.send(payload.value)
            guard reply["ok"] as? Bool == true else { throw Refused(message: reply["error"] as? String ?? "the broker refused") }
            return JSONBox(value: reply)
        }.value
        return reply.value
    }

    /// A JSON object crossing the actor boundary once, never shared afterwards.
    private struct JSONBox: @unchecked Sendable { let value: [String: Any] }
}
