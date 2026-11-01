import Foundation
import Testing

/// A value handed to another thread by a test that joins it before reading.
struct U25R2Shared<Value>: @unchecked Sendable { let value: Value }

extension U25Rig {
    /// The same stubs plus a hook that makes a seat child wake the council (`<seat>.<round>.child`).
    func installChildWakeStubs() throws {
        for kind in ["codex", "claude", "opencode", "hermes"] {
            let url = base.bin.appendingPathComponent(kind)
            try Data(contentsOf: brokerFixture("u25r2-seat.sh")).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    /// Serves the broker again with extra environment (for example a pinned free-memory reading).
    func restart(environment extra: [String: String]) throws {
        base.broker?.kill(); _ = try base.broker?.finish()
        var env = ["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": base.bin.path,
                   "HOME": packet.fakeHome.path, "STUB_DIR": control.path,
                   "STUB_CLI": try brokerBinary().path,
                   "AGENCIL_TEST_SANDBOX_EXEC": base.bin.appendingPathComponent("u25-sandbox").path]
        env.merge(extra) { _, new in new }
        base.broker = try home.serve(env)
    }

    func wake(authorVendor: String) throws -> [String: Any] {
        try request("wake", ["council": "panel", "question": "inspect harbor", "change_kind": "design",
                             "author_vendor": authorVendor, "wait_seconds": 10])
    }
}
