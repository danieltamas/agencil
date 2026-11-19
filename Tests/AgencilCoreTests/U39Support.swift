@testable import AgencilCore
import Foundation
import Testing

enum U39Support {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(token: String, refresh: String, expires: Date?) throws -> Data {
        var oauth: [String: Any] = ["accessToken": token, "refreshToken": refresh]
        if let expires { oauth["expiresAt"] = expires.timeIntervalSince1970 * 1_000 }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func securityStub(in folder: URL, item: Data, exit: Int = 0) throws -> (tool: URL, marker: URL) {
        let tool = folder.appendingPathComponent("security-stub")
        let marker = folder.appendingPathComponent("security-ran")
        let script = """
        #!/bin/sh
        /usr/bin/touch \(quote(marker.path)) || exit 91
        printf '%s' \(quote(String(decoding: item, as: UTF8.self)))
        exit \(exit)
        """
        try U34Support.put(tool, script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        return (tool, marker)
    }

    static func files(in folder: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        var result: [URL] = []
        for child in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result += try files(in: child)
            } else {
                result.append(child)
            }
        }
        return result
    }
}

final class U39Rig {
    let rig: U6dRig
    // The item-bearing security script is outside the broker home and all scanned directories.
    let securityHome: BrokerHome
    let token = "u39-token-" + UUID().uuidString
    let refresh = "u39-refresh-" + UUID().uuidString
    let confined: Bool
    let marker: URL

    init(harness: String = "claude", confined: Bool = true, security: Bool = true,
         expired: Bool = false) throws {
        rig = try U6dRig()
        securityHome = try BrokerHome()
        self.confined = confined
        rig.base.broker?.kill()
        _ = try rig.base.broker?.finish()
        let item = try U39Support.item(token: token, refresh: refresh,
                                      expires: Date().addingTimeInterval(expired ? -3_600 : 3_600))
        let stub = try U39Support.securityStub(in: securityHome.url, item: item)
        marker = stub.marker
        // U6dRig already installs both harnesses. Insert observations after probes return,
        // so "started" means an answering invocation, not --version or auth status.
        let executable = rig.base.bin.appendingPathComponent(harness)
        let script = try String(contentsOf: executable, encoding: .utf8)
        let anchor = "printf '%s\\n' \"$PWD\" > \"$record.cwd\""
        try #require(script.contains(anchor))
        let observation = """
        printf 'started' > "$record.u39-started" || exit 92
        printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN+set}" > "$record.u39-token-present" || exit 93
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > "$record.u39-token" || exit 94
        printf '%s' "$CLAUDE_CODE_TMPDIR" > "$record.u39-tmpdir" || exit 95
        printf '%s' "$TMPDIR" > "$record.u39-system-tmpdir" || exit 96
        /usr/bin/env > "$record.u39-environment" || exit 97
        """
        try script.replacingOccurrences(of: anchor, with: anchor + "\n" + observation)
            .write(to: executable, atomically: false, encoding: .utf8)
        if confined { try rig.repository() }
        try rig.configure([u6aSeat("primary", harness)])
        var environment = ["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": rig.base.bin.path,
                           "HOME": rig.fakeHome.path, "STUB_MODE": "answer",
                           "STUB_RECORD": rig.base.record.path, "STUB_REAL_REPO": rig.repo.path,
                           "AGENCIL_TEST_SANDBOX_EXEC": rig.base.bin.appendingPathComponent("sandbox-launch").path]
        if security { environment["AGENCIL_TEST_SECURITY"] = stub.tool.path }
        // BrokerProcess inherits its parent's environment. Explicitly remove inherited credentials
        // and the security seam, then install only this fixture's optional security path.
        var arguments = ["-u", "AGENCIL_TEST_SECURITY", "-u", "CLAUDE_CODE_OAUTH_TOKEN"]
        if security { arguments.append("AGENCIL_TEST_SECURITY=" + stub.tool.path) }
        arguments += [try brokerBinary().path, "serve"]
        rig.base.broker = try BrokerProcess(arguments, home: rig.home.url, env: environment,
                                           executable: URL(fileURLWithPath: "/usr/bin/env"))
        try brokerPoll { (try? self.rig.home.request(["op": "ping"])["ok"] as? Bool) == true }
    }

    func ask() throws -> [String: Any] { try rig.ask(repo: confined) }

    func observation(_ suffix: String) throws -> String {
        try confined ? rig.observation(suffix) : rig.base.contents(suffix)
    }

    func assertLaunchedWithoutToken() throws {
        #expect(try observation(".u39-started") == "started")
        #expect(try observation(".u39-token-present").isEmpty)
        #expect(try observation(".u39-token").isEmpty)
        #expect(try !observation(".u39-environment").contains(refresh))
    }

    func assertNeverLaunched() throws {
        let files = try U39Support.files(in: rig.home.url.appendingPathComponent("runs"))
        #expect(!files.contains { $0.lastPathComponent == "u6d.u39-started" })
        #expect(!FileManager.default.fileExists(atPath: rig.base.record.path + ".u39-started"))
    }

    func assertNoPersistedCredentials() throws {
        let fm = FileManager.default
        let database = rig.home.url.appendingPathComponent("agencil.sqlite")
        try #require(fm.fileExists(atPath: database.path))
        var paths = [database]
        let wal = rig.home.url.appendingPathComponent("agencil.sqlite-wal")
        if fm.fileExists(atPath: wal.path) { paths.append(wal) }
        paths += try U39Support.files(in: rig.home.url.appendingPathComponent("logs"))
        paths += try U39Support.files(in: rig.home.url.appendingPathComponent("runs"))
        // Only these exact test-owned files may contain T. R is forbidden even in observations.
        let observations = Set(["u6d.u39-token", "u6d.u39-environment"])
        for path in paths {
            let bytes = try Data(contentsOf: path)
            #expect(bytes.range(of: Data(refresh.utf8)) == nil, "Refresh token persisted in \(path.lastPathComponent)")
            if !observations.contains(path.lastPathComponent) {
                #expect(bytes.range(of: Data(token.utf8)) == nil, "Access token persisted in \(path.lastPathComponent)")
            }
        }
    }
}
