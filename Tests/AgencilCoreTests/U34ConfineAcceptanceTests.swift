@testable import AgencilCore
import Foundation
import Testing

@Suite(.serialized)
struct U34ConfineAcceptanceTests {
    // Acceptance 1: link directories, package boundaries and resolved spellings.
    @Test func executableReadsRespectPackageBoundaries() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for target in ["lib/node_modules/@scope/pkg/bin/tool.js", "lib/node_modules/pkg/bin/x.js",
                       "other/versions/1.2.3"] {
            let destination = root.appendingPathComponent(target)
            try U34Support.put(destination, "fixture")
            let link = bin.appendingPathComponent("tool")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../" + target)
            let reads = Set(Confinement.executableReads(link.path))
            var expected = Set([U34Support.resolved(bin), U34Support.resolved(destination.deletingLastPathComponent())])
            if target.contains("node_modules") {
                let package = target.contains("@scope") ? "lib/node_modules/@scope/pkg" : "lib/node_modules/pkg"
                expected.insert(U34Support.resolved(root.appendingPathComponent(package)))
            }
            #expect(reads == expected)
            #expect(!reads.contains(U34Support.resolved(root.appendingPathComponent("lib/node_modules"))))
            #expect(!reads.contains(U34Support.resolved(root.appendingPathComponent("lib"))))
            try fm.removeItem(at: link)
        }
        let plain = bin.appendingPathComponent("plain")
        try U34Support.put(plain, "fixture")
        #expect(Set(Confinement.executableReads(plain.path)) == [U34Support.resolved(bin)])
    }

    // Acceptance 2: broad target directories become executable-file grants.
    @Test(arguments: ["owner/tool", "node_modules/tool"])
    func profileRefusesBroadExecutableDirectories(target: String) throws {
        let fixture = try BrokerHome(), root = fixture.url
        let destination = root.appendingPathComponent(target)
        try U34Support.put(destination, "fixture")
        let link = root.appendingPathComponent("bin/tool")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let profile = U34Support.profile(root, executable: link.path)
        #expect(U34Support.grantsLiteralRead(profile, path: U34Support.resolved(destination)))
        var forbidden = destination.deletingLastPathComponent()
        while true {
            for path in Set([forbidden.path, U34Support.resolved(forbidden)]) {
                #expect(!profile.contains("(subpath \"\(path)\")"))
            }
            if forbidden.path == "/" { break }
            forbidden.deleteLastPathComponent()
        }
    }

    // Acceptance 3: literal resolver reads, not a blanket run-directory grant.
    @Test func profileGrantsResolverLiterals() throws {
        let fixture = try BrokerHome()
        let profile = U34Support.profile(fixture.url)
        for path in ["/var", "/private/var/run", "/private/var/run/mDNSResponder"] {
            #expect(U34Support.grantsLiteralRead(profile, path: path))
        }
        #expect(!profile.contains("(subpath \"/private/var/run\")"))
    }

    // Acceptance 4, package access half: invoke Python through a package link.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func realSandboxReadsLinkedPackageButDeniesSibling() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let target = root.appendingPathComponent("lib/node_modules/@scope/pkg/bin/python")
        try U34Support.put(target, "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let link = root.appendingPathComponent("bin/tool")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path,
            withDestinationPath: "../lib/node_modules/@scope/pkg/bin/python")
        let own = root.appendingPathComponent("lib/node_modules/@scope/pkg/data.txt")
        let sibling = root.appendingPathComponent("lib/node_modules/@scope/sibling/data.txt")
        try U34Support.put(own, "PACKAGE_MARKER"); try U34Support.put(sibling, "SIBLING_MARKER")
        let code = """
        import sys
        assert open(sys.argv[1]).read() == 'PACKAGE_MARKER'
        try:
            open(sys.argv[2]).read()
        except PermissionError:
            pass
        else:
            raise AssertionError('sibling package readable')
        """
        let result = try U34Support.python(root, profile: U34Support.profile(root, executable: link.path),
            code: code, arguments: [own.path, sibling.path], executable: link.path)
        #expect(result.0 == 0, "\(result)")
    }

    // Acceptance 4, resolver half: local AF_UNIX only, no DNS or network request.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"),
          .enabled(if: FileManager.default.fileExists(atPath: "/var/run/mDNSResponder"), "resolver socket is absent"))
    func realSandboxConnectsToResolverSocket() throws {
        let fixture = try BrokerHome()
        let code = "import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect('/var/run/mDNSResponder'); s.close()"
        let result = try U34Support.python(fixture.url, profile: U34Support.profile(fixture.url), code: code)
        #expect(result.0 == 0, "\(result)")
    }

    // Acceptance 5.
    @Test func profileRemovesRealCodexHomeAndRetainsClaudeHome() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = URL(fileURLWithPath: U34Support.testHome(root))
        let codex = U34Support.profile(root)
        for path in [home.appendingPathComponent(".codex").path,
                     U34Support.resolved(home.appendingPathComponent(".codex"))] {
            #expect(!codex.contains(path))
        }
        #expect(U34Support.profile(root, harness: "claude").contains(
            U34Support.resolved(home.appendingPathComponent(".claude"))))
    }

    // Acceptance 6.
    @Test(arguments: ["codex", "missing", "claude", "opencode", "hermes"])
    func prepareCreatesOnlyCodexHome(scenario: String) throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = U34Support.testHome(root), run = root.appendingPathComponent("run")
        let original = try U34Support.bytes(U34Support.login())
        if scenario != "missing" { try U34Support.put(URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json"), original) }
        let prepared = try SeatHome.prepare(harness: scenario == "missing" ? "codex" : scenario, runDirectory: run, home: home)
        let directory = run.appendingPathComponent("home/.codex")
        if ["claude", "opencode", "hermes"].contains(scenario) {
            #expect(prepared == nil)
            #expect(!FileManager.default.fileExists(atPath: run.appendingPathComponent("home").path))
            return
        }
        let value = try #require(prepared)
        #expect(value == ["CODEX_HOME": directory.path])
        #expect(try U34Support.mode(run.appendingPathComponent("home")) == 0o700)
        #expect(try U34Support.mode(directory) == 0o700)
        let auth = directory.appendingPathComponent("auth.json")
        if scenario == "missing" {
            #expect(!FileManager.default.fileExists(atPath: auth.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        } else {
            #expect(try Data(contentsOf: auth) == original)
            #expect(try U34Support.mode(auth) == 0o600)
        }
    }

    // Acceptance 7: the test owner home lies outside the writable run.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func realSandboxWritesPrivateCodexHomeAndDeniesOwnerLogin() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = U34Support.testHome(root), run = root.appendingPathComponent("run")
        let auth = URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
        let original = try U34Support.bytes(U34Support.login())
        try U34Support.put(auth, original)
        let prepared = try #require(try SeatHome.prepare(harness: "codex", runDirectory: run, home: home))
        let code = """
        import os,sys
        path=os.path.join(os.environ['CODEX_HOME'], 'config.toml')
        with open(path, 'w') as f: f.write('PRIVATE_MARKER')
        assert open(path).read() == 'PRIVATE_MARKER'
        for mode in ['r', 'w']:
            try:
                open(sys.argv[1], mode)
            except PermissionError:
                pass
            else:
                raise AssertionError('owner auth accessible: ' + mode)
        """
        let result = try U34Support.python(root, profile: U34Support.profile(root), code: code,
            arguments: [auth.path], environment: prepared)
        #expect(result.0 == 0, "\(result)")
        #expect(try Data(contentsOf: auth) == original)
    }

    // Acceptance 8: reuse the actual broker, adapters, repository and sandbox rig.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func confinedBrokerAskUsesRunHomeAndRemovesItAfterExchange() throws {
        let rig = try U6dRig()
        let ownerAuth = rig.fakeHome.appendingPathComponent(".codex/auth.json")
        let original = try U34Support.bytes(U34Support.login())
        let rewritten = String(decoding: try U34Support.bytes(U34Support.login(accessToken: "seat-access")), as: UTF8.self)
        try U34Support.put(ownerAuth, original)
        let stub = rig.base.bin.appendingPathComponent("codex")
        let script = try String(contentsOf: stub, encoding: .utf8)
        let anchor = "printf '%s\\n' \"$PWD\" > \"$record.cwd\""
        try #require(script.contains(anchor))
        let rewrite = """
        printf '%s\\n' "$CODEX_HOME" > "$record.codex-home"
        printf '%s' '\(rewritten)' > "$CODEX_HOME/auth.json" || exit 71
        /bin/cat "$CODEX_HOME/auth.json" > "$record.rewritten-auth" || exit 72
        """
        try script.replacingOccurrences(of: anchor, with: anchor + "\n" + rewrite)
            .write(to: stub, atomically: false, encoding: .utf8)
        try rig.repository()
        _ = try rig.base.answered(rig.ask())
        let cwd = URL(fileURLWithPath: try rig.observation(".cwd").trimmingCharacters(in: .whitespacesAndNewlines))
        let run = cwd.deletingLastPathComponent()
        let observed = URL(fileURLWithPath: try rig.observation(".codex-home").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(U34Support.resolved(observed) == U34Support.resolved(run.appendingPathComponent("home/.codex")))
        #expect(U34Support.resolved(run).hasPrefix(U34Support.resolved(rig.home.url.appendingPathComponent("runs")) + "/"))
        #expect(try rig.observation(".rewritten-auth") == rewritten)
        try brokerPoll(10) { !FileManager.default.fileExists(atPath: run.appendingPathComponent("home").path) }
        #expect(try Data(contentsOf: ownerAuth) == original)
    }
}
