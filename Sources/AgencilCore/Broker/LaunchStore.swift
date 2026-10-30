import Foundation
import Security

/// One process the broker starts through the launcher handshake, as the ledger remembers it.
public struct Launch: Sendable, Equatable {
    public enum State: String, Sendable { case intent, running, exited, interrupted }
    public let id: String
    public let nonce: String
    public let argv: [String]
    public let cwd: String
    public let env: [String: String]
    public let reservedSeconds: Int
    public var state: State
    public var reserved: Bool
    public var pid: Int32?
    public var pgid: Int32?
    public var startTime: Double?
    public var registeredAt: Double?
}

/// The durable side of the launch handshake: the intent is written before anything is spawned, the identity
/// before the harness may start, and the reservation is released only when the group is proven empty.
public struct LaunchStore: Sendable {
    let ledger: Ledger

    public init(ledger: Ledger) { self.ledger = ledger }

    private static let columns = "id, nonce, argv, cwd, env, reserved_seconds, state, reserved, pid, pgid, start_time, registered_at"

    public func createIntent(argv: [String], cwd: String, env: [String: String], reservedSeconds: Int) throws -> Launch {
        let id = UUID().uuidString, nonce = Self.randomNonce()
        let argvJSON = try Self.encode(argv), envJSON = try Self.encode(env)
        try ledger.locked {
            try ledger.run("""
                INSERT INTO launches (id, nonce, argv, cwd, env, reserved_seconds, state, reserved, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'intent', 1, ?);
                """, [id, nonce, argvJSON, cwd, envJSON, String(reservedSeconds), String(Date().timeIntervalSince1970)])
        }
        return Launch(id: id, nonce: nonce, argv: argv, cwd: cwd, env: env, reservedSeconds: reservedSeconds,
                      state: .intent, reserved: true)
    }

    /// The identity of the process that will exec the harness, recorded before it is told to go.
    public func register(id: String, pid: Int32, pgid: Int32, startTime: Double) throws -> Double {
        let now = Date().timeIntervalSince1970
        try ledger.locked {
            try ledger.run("UPDATE launches SET state = 'running', pid = ?, pgid = ?, start_time = ?, registered_at = ? WHERE id = ? AND state = 'intent';",
                           [String(pid), String(pgid), String(startTime), String(now), id])
        }
        return now
    }

    /// Ends the launch and releases its reservation. Callers prove the group empty first.
    public func finish(id: String, state: Launch.State) throws {
        try ledger.locked {
            try ledger.run("UPDATE launches SET state = ?, reserved = 0, ended_at = ? WHERE id = ? AND reserved = 1;",
                           [state.rawValue, String(Date().timeIntervalSince1970), id])
        }
    }

    /// The pid that made an acting request, kept with the request for accounting and loop control.
    public func recordRequest(peer: Int32?) throws {
        try ledger.locked {
            try ledger.run("INSERT INTO requests (id, caller, created_at) VALUES (?, ?, ?);",
                           [UUID().uuidString, peer.map { "pid:\($0)" } ?? "pid:unknown",
                            ISO8601DateFormatter().string(from: Date())])
        }
    }

    public func launch(id: String) throws -> Launch? {
        try ledger.locked { try fetch("SELECT \(Self.columns) FROM launches WHERE id = ?;", [id]).first }
    }

    public func launch(nonce: String) throws -> Launch? {
        try ledger.locked { try fetch("SELECT \(Self.columns) FROM launches WHERE nonce = ?;", [nonce]).first }
    }

    /// Every launch whose reservation is still held.
    public func open() throws -> [Launch] {
        try ledger.locked { try fetch("SELECT \(Self.columns) FROM launches WHERE reserved = 1;", []) }
    }

    private func fetch(_ sql: String, _ values: [String?]) throws -> [Launch] {
        try ledger.query(sql, values) { statement in
            func text(_ column: Int32) -> String? { Ledger.text(statement, column) }
            func integer(_ column: Int32) -> Int32? { text(column).flatMap { Int32($0) } }
            func real(_ column: Int32) -> Double? { text(column).flatMap { Double($0) } }
            return Launch(
                id: text(0) ?? "", nonce: text(1) ?? "", argv: Self.decode(text(2)) ?? [], cwd: text(3) ?? "",
                env: Self.decode(text(4)) ?? [:], reservedSeconds: Int(text(5) ?? "") ?? 0,
                state: Launch.State(rawValue: text(6) ?? "") ?? .interrupted, reserved: text(7) == "1",
                pid: integer(8), pgid: integer(9), startTime: real(10), registeredAt: real(11))
        }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ text: String?) -> T? {
        text.flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
}
