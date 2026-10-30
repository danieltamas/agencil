import Foundation
import SQLite3

/// `agencil.sqlite` in the Agencil home, through the system libsqlite3. Every statement is prepared and bound;
/// no value is ever spliced into SQL text.
public final class Ledger: @unchecked Sendable {
    public struct Claim: Sendable, Equatable {
        public let id: String
        public let body: String
        public let supersedes: String?
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { "ledger: \(message)" }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let database: OpaquePointer
    private let lock = NSLock()

    public init(directory: URL) throws {
        let path = directory.appendingPathComponent("agencil.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        database = handle
        chmod(path, 0o600)
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
        try migrate()
    }

    deinit { sqlite3_close(database) }

    /// Applies every migration above the file's `user_version`, each in its own transaction. Safe to repeat.
    public func migrate() throws {
        lock.lock(); defer { lock.unlock() }
        // The version is read inside the write transaction: another process may have migrated since we opened.
        try execute("BEGIN IMMEDIATE;")
        do {
            let current = try scalarInt("PRAGMA user_version;")
            for (index, sql) in LedgerSchema.migrations.enumerated() where index + 1 > current {
                try execute(sql)
                try execute("PRAGMA user_version = \(index + 1);")
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// A new row; with `superseding` it names the row it corrects, which stays readable.
    public func appendClaim(body: String, superseding: String? = nil) throws -> Claim {
        lock.lock(); defer { lock.unlock() }
        let id = UUID().uuidString
        try run("INSERT INTO claims (id, body, supersedes, created_at) VALUES (?, ?, ?, ?);",
                [id, body, superseding, ISO8601DateFormatter().string(from: Date())])
        return Claim(id: id, body: body, supersedes: superseding)
    }

    /// Runs `body` with the ledger's lock held, so a multi-statement change is not interleaved with another thread's.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public func claim(id: String) throws -> Claim? {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT id, body, supersedes FROM claims WHERE id = ?;", [id]) { statement in
            Claim(id: Self.text(statement, 0) ?? "", body: Self.text(statement, 1) ?? "", supersedes: Self.text(statement, 2))
        }.first
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw Failure(message: message.map { String(cString: $0) } ?? "statement failed")
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try query(sql, []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    func run(_ sql: String, _ values: [String?]) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [String?], row: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            // Bound by byte length: a NUL inside the text is data, not the end of it.
            let bound = value.map { text in
                Array(text.utf8).withUnsafeBufferPointer { bytes in
                    bytes.baseAddress.map { base in
                        base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                            sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(bytes.count), Self.transient)
                        }
                    } ?? sqlite3_bind_text(statement, Int32(offset + 1), "", 0, Self.transient)
                }
            } ?? sqlite3_bind_null(statement, Int32(offset + 1))
            guard bound == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(database))) }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(statement))
            case SQLITE_DONE: return rows
            default: throw Failure(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
}
