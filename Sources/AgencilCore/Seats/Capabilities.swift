import CryptoKit
import Foundation
import Security

/// What a capability stands for: the seat run it was issued to.
struct CapabilityRun: Equatable {
    let thread: String
    let seq: Int
    let launchID: String
    let seat: String
    let chain: [String]
    /// A capability is live exactly while its exchange is asking.
    let live: Bool
}

extension ThreadStore {
    /// 256 random bits as 64 hex characters; the caller keeps the token, the ledger gets its hash.
    static func newCapability() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess { bytes = (0..<32).map { _ in UInt8.random(in: 0...255) } }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func issueCapability(_ token: String, launch: String, thread: String, seq: Int) throws {
        try ledger.locked {
            try ledger.run("INSERT INTO capabilities (hash, thread_id, seq, launch_id, created_at) VALUES (?, ?, ?, ?, ?);",
                           [Self.hash(token), thread, String(seq), launch, ISO8601DateFormatter().string(from: Date())])
        }
    }

    /// The run a presented token was issued to, or nil when no such token was ever issued.
    func capability(token: String) throws -> CapabilityRun? {
        try run(where: "c.hash = ?", Self.hash(token))
    }

    /// The seat run that owns this launch, or nil when the launch was not an ask.
    func capability(launch: String) throws -> CapabilityRun? {
        try run(where: "c.launch_id = ?", launch)
    }

    private func run(where clause: String, _ value: String) throws -> CapabilityRun? {
        try ledger.locked {
            try ledger.query("""
                SELECT c.thread_id, c.seq, c.launch_id, t.seat, e.chain, e.state FROM capabilities c
                JOIN exchanges e ON e.thread_id = c.thread_id AND e.seq = c.seq
                JOIN threads t ON t.id = c.thread_id WHERE \(clause);
                """, [value]) {
                CapabilityRun(thread: Ledger.text($0, 0) ?? "", seq: Int(Ledger.text($0, 1) ?? "") ?? 0,
                              launchID: Ledger.text($0, 2) ?? "", seat: Ledger.text($0, 3) ?? "",
                              chain: Self.decode(Ledger.text($0, 4)), live: Ledger.text($0, 5) == "asking")
            }.first
        }
    }
}
