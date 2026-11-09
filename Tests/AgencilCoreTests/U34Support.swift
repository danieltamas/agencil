@testable import AgencilCore
import Foundation
import Testing

enum U34Support {
    static let sandboxAvailable: Bool = {
        let p = Process(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        p.standardError = errors
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 { return true }
            print("sandbox-exec cannot apply a profile: " +
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        } catch { print("sandbox-exec unavailable: \(error)") }
        return false
    }()

    static func put(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func put(_ url: URL, _ text: String) throws { try put(url, Data(text.utf8)) }
    static func resolved(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.path }
        defer { free(path) }
        return String(cString: path)
    }
    static func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    static func grantsLiteralRead(_ profile: String, path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: path)
        let pattern = #"\(allow\s+file-read\*(?:[^()]|\([^()]*\))*?\(literal "\#(escaped)"\)"#
        return profile.range(of: pattern, options: .regularExpression) != nil
    }

    static func profile(_ root: URL, executable: String = "/usr/bin/python3", harness: String = "codex") -> String {
        Confinement.profile(copy: root.appendingPathComponent("run/copy").path,
            runDirectory: root.appendingPathComponent("run").path, executable: executable,
            harness: harness, home: testHome(root), brokerHome: root.appendingPathComponent("broker").path)
    }

    static func testHome(_ root: URL) -> String {
        Confinement.home(environment: ["AGENCIL_TEST_SEAMS": "1", "HOME": root.appendingPathComponent("owner").path])
    }

    static func python(_ root: URL, profile: String, code: String, arguments: [String] = [],
                       environment: [String: String] = [:], executable: String = "/usr/bin/python3") throws -> (Int32, String, String) {
        let file = root.appendingPathComponent("profile.sb")
        try profile.write(to: file, atomically: true, encoding: .utf8)
        let p = try BrokerProcess(["-f", file.path, executable, "-I", "-c", code] + arguments,
            home: root, env: environment, executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"))
        return try p.finish(15)
    }

    static func login(accessToken: String = "old-access") -> [String: Any] {
        ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
         "tokens": ["account_id": "fixture-account", "access_token": accessToken,
                    "refresh_token": "old-refresh", "id_token": "old-id"],
         "last_refresh": "2026-01-01T00:00:00Z"]
    }

    static func bytes(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
