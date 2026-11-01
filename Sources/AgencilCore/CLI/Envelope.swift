import Foundation

/// The versioned wrapper every `--json` output and every MCP result carries (docs/AGENT-API.md).
public enum Envelope {
    public static let api = 1

    public static func make(data: Any, note: String) -> [String: Any] {
        ["ok": true, "api": api, "source": "agencil", "generated_at": ISO8601DateFormatter().string(from: Date()),
         "data_note": note, "data": data]
    }

    public static func text(_ envelope: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A thin client of the broker socket: one request, one reply.
public struct BrokerClient: Sendable {
    public static let notRunning = "Agencil is not running (open the app or run agencil serve)"

    public struct Failure: Error { public let message: String; public let exit: Int32 }

    let socketPath: String

    public init(home: AgencilHome) {
        socketPath = home.socketPath
    }

    public func send(_ request: [String: Any]) throws -> [String: Any] {
        let connected: Int32?
        do { connected = try UnixSocket.connect(to: socketPath) } catch {
            throw Failure(message: error.localizedDescription, exit: 70)
        }
        guard let descriptor = connected else { throw Failure(message: Self.notRunning, exit: 3) }
        defer { close(descriptor) }
        guard UnixSocket.write(descriptor, line: UnixSocket.json(request)),
              case .line(let data) = UnixSocket.Reader(descriptor: descriptor).next(),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(message: Self.notRunning, exit: 3)
        }
        return reply
    }
}
