import Foundation
import Testing

final class U6dRig {
    let budget: U6cRig
    var base: U6aRig { budget.base }
    var home: BrokerHome { base.home }
    let fakeHome: URL
    let repo: URL
    init(mode: String = "answer", sandbox: String? = nil) throws {
        budget = try U6cRig()
        fakeHome = budget.home.url.appendingPathComponent("decoy")
        repo = budget.home.url.appendingPathComponent("repository")
        base.broker?.kill(); _ = try base.broker?.finish()
        for path in [".ssh/id_ed25519", ".codex/config.toml", ".claude/settings.json"] {
            try put(fakeHome.appendingPathComponent(path), path.hasPrefix(".ssh") ? "HOME_DENIED_MARKER" : "HARNESS_ALLOWED_MARKER")
        }
        for kind in ["codex", "claude", "opencode", "hermes"] {
            let file = base.bin.appendingPathComponent(kind)
            try Data(contentsOf: brokerFixture("u6d-seat.sh")).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let wrapper = base.bin.appendingPathComponent("sandbox-launch")
        try put(wrapper, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$STUB_RECORD.sandbox\"\nexec /usr/bin/sandbox-exec \"$@\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        base.broker = try home.serve(["AGENCIL_TEST_SEAMS": "1", "AGENCIL_PATH_PREFIX": base.bin.path,
            "HOME": fakeHome.path, "STUB_MODE": mode, "STUB_RECORD": base.record.path,
            "STUB_REAL_REPO": repo.path, "AGENCIL_TEST_SANDBOX_EXEC": sandbox ?? wrapper.path])
    }
    func put(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func repository(_ files: [String: String] = ["README": "COMMITTED_MARKER", "src/main.swift": "print(1)"] , symlink: Bool = false) throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for (name, text) in files { try put(repo.appendingPathComponent(name), text) }
        if symlink { try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("home-link"), withDestinationURL: fakeHome) }
        for args in [["init", repo.path], ["-C", repo.path, "add", "."],
                     ["-C", repo.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"]] {
            let p = try BrokerProcess(args, home: home.url, executable: URL(fileURLWithPath: "/usr/bin/git"))
            #expect(try p.finish().0 == 0)
        }
        try put(repo.appendingPathComponent("README"), "UNCOMMITTED_MARKER")
    }
    func configure(_ seats: [[String: Any]] = [u6aSeat()], route: [String: Any] = u6aRoute()) throws {
        try budget.configure(seats, routes: [route])
    }
    func ask(repo: Bool = true, extra: [String: Any] = [:]) throws -> [String: Any] {
        try base.ask(extra: (repo ? ["repo": self.repo.path] : [:]).merging(extra) { _, b in b })
    }
    func observation(_ suffix: String) throws -> String {
        var found: URL?
        try brokerPoll(10) {
            let urls = FileManager.default.enumerator(at: self.home.url.appendingPathComponent("runs"), includingPropertiesForKeys: nil)
            while let url = urls?.nextObject() as? URL {
                if url.lastPathComponent == "u6d" + suffix { found = url }
            }
            return found != nil
        }
        return try String(contentsOf: #require(found), encoding: .utf8)
    }
    func removedCopy() throws {
        let cwd = try observation(".cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasPrefix(home.url.path + "/runs/th_"))
        #expect(cwd.hasSuffix("-1/copy"))
        try brokerPoll(10) { !FileManager.default.fileExists(atPath: cwd) }
    }
    func noRun() throws {
        base.noAnswerSpawned()
        #expect(!FileManager.default.fileExists(atPath: base.record.path + ".argv"))
        #expect(try budget.sql("SELECT count(*) FROM runs; SELECT count(*) FROM reservations;") == "0\n0\n")
        #expect(try budget.sql(".dump requests").contains("refused"))
    }
}

func u6dRoute(_ extra: [String: Any], fallbacks: [String] = []) -> [String: Any] {
    u6aRoute(fallbacks: fallbacks).merging(extra) { _, b in b }
}
