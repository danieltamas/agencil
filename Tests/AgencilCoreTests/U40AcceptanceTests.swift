@testable import AgencilCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U40AcceptanceTests {
    // Acceptance 1: exactly three XDG variables, with private directories.
    @Test func prepareOpenCodeCreatesPrivateXDGDirectories() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let run = root.appendingPathComponent("run")
        let prepared = try SeatHome.prepare(harness: "opencode", runDirectory: run,
                                            home: U34Support.testHome(root))
        #expect(prepared == U40Support.environment(run))
        for path in ["home", "home/data", "home/state", "home/cache"] {
            let directory = run.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #expect(try U34Support.mode(directory) == 0o700)
        }
    }

    // Acceptance 2: test each seed independently, including the inclusive size boundary.
    @Test(arguments: ["regular", "limit", "link", "missing", "oversized"], [0, 1])
    func prepareOpenCodeCopiesOnlyEligibleSeeds(scenario: String, seedIndex: Int) throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = URL(fileURLWithPath: U34Support.testHome(root))
        let run = root.appendingPathComponent("run"), fm = FileManager.default
        let sources = [".local/share/opencode/auth.json", ".cache/opencode/models.json"]
        let targets = ["home/data/opencode/auth.json", "home/cache/opencode/models.json"]
        var originals = [Data("{\"token\":\"fixture-access\"}\n".utf8), Data("{\"models\":[]}\n".utf8)]
        for index in sources.indices {
            let source = home.appendingPathComponent(sources[index])
            let variant = index == seedIndex ? scenario : "regular"
            if variant == "missing" { continue }
            if variant == "link" {
                let target = root.appendingPathComponent("linked-seed.json")
                try U34Support.put(target, originals[index])
                try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: source, withDestinationURL: target)
            } else {
                if variant == "limit" || variant == "oversized" {
                    originals[index] = Data(repeating: 0x61, count: (32 << 20) + (variant == "oversized" ? 1 : 0))
                }
                try U34Support.put(source, originals[index])
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
            }
        }
        let prepared = try SeatHome.prepare(harness: "opencode", runDirectory: run, home: home.path)
        #expect(prepared == U40Support.environment(run))
        for index in targets.indices {
            let target = run.appendingPathComponent(targets[index])
            if index == seedIndex && ["link", "missing", "oversized"].contains(scenario) {
                // attributesOfItem also detects an incorrectly copied symbolic link.
                #expect((try? fm.attributesOfItem(atPath: target.path)) == nil)
            } else {
                #expect(try Data(contentsOf: target) == originals[index])
                #expect(try U34Support.mode(target) == 0o600)
                let attributes = try fm.attributesOfItem(atPath: target.path)
                #expect(attributes[.type] as? FileAttributeType == .typeRegular)
            }
        }
    }

    // Acceptance 3: no home for Claude/Hermes; Codex retains its U34 preparation contract.
    @Test func prepareOtherHarnessesRetainsU34Behavior() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = U34Support.testHome(root), fm = FileManager.default
        for harness in ["claude", "hermes"] {
            let run = root.appendingPathComponent(harness)
            let prepared = try SeatHome.prepare(harness: harness, runDirectory: run, home: home)
            #expect(prepared == nil)
            #expect(!fm.fileExists(atPath: run.path))
        }
        let ownerAuth = URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
        let original = try U34Support.bytes(U34Support.login())
        for seeded in [false, true] {
            if seeded { try U34Support.put(ownerAuth, original) }
            let run = root.appendingPathComponent(seeded ? "codex-seeded" : "codex-missing")
            let directory = run.appendingPathComponent("home/.codex")
            let prepared = try SeatHome.prepare(harness: "codex", runDirectory: run, home: home)
            #expect(prepared == ["CODEX_HOME": directory.path])
            #expect(try U34Support.mode(run.appendingPathComponent("home")) == 0o700)
            #expect(try U34Support.mode(directory) == 0o700)
            if seeded {
                let copy = directory.appendingPathComponent("auth.json")
                #expect(try Data(contentsOf: copy) == original)
                #expect(try U34Support.mode(copy) == 0o600)
                try U34Support.put(copy, "seat-rewritten-login")
                #expect(try Data(contentsOf: ownerAuth) == original)
            } else {
                #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
            }
        }
    }

    // Acceptance 4: retain the read-only config grant, remove the owner's data grant.
    @Test func openCodeProfileGrantsConfigButNotOwnerData() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = URL(fileURLWithPath: U34Support.testHome(root))
        let config = home.appendingPathComponent(".config/opencode")
        let data = home.appendingPathComponent(".local/share/opencode")
        try U34Support.put(config.appendingPathComponent("opencode.json"), "{}")
        try U34Support.put(data.appendingPathComponent("auth.json"), "owner-login")
        let profile = U34Support.profile(root, harness: "opencode")
        let path = NSRegularExpression.escapedPattern(for: U34Support.resolved(config))
        let readGrant = #"\(allow\s+file-read\*(?:[^()]|\([^()]*\))*?\(subpath "\#(path)"\)"#
        #expect(profile.range(of: readGrant, options: .regularExpression) != nil)
        for spelling in Set([data.path, U34Support.resolved(data)]) {
            #expect(!profile.contains(spelling))
        }
        for line in profile.split(separator: "\n") where line.contains("(allow file-write") {
            #expect(!line.contains(U34Support.resolved(config)))
        }
    }

    // Acceptance 5: exercise the prepared environment under the real kernel sandbox.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func realSandboxWritesOpenCodeStateAndCacheButDeniesOwnerAuth() throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = U34Support.testHome(root), run = root.appendingPathComponent("run")
        let auth = URL(fileURLWithPath: home).appendingPathComponent(".local/share/opencode/auth.json")
        try U34Support.put(auth, "OWNER_LOGIN_MARKER")
        let prepared = try #require(try SeatHome.prepare(harness: "opencode", runDirectory: run, home: home))
        let code = """
        import os,sys
        for variable, suffix in [('XDG_STATE_HOME', 'opencode'), ('XDG_CACHE_HOME', 'opencode/bin')]:
            path = os.path.join(os.environ[variable], suffix)
            os.makedirs(path)
            marker = os.path.join(path, 'marker')
            with open(marker, 'w') as stream: stream.write('PRIVATE_MARKER')
            assert open(marker).read() == 'PRIVATE_MARKER'
        assert open(os.path.join(os.environ['XDG_DATA_HOME'], 'opencode/auth.json')).read() == 'OWNER_LOGIN_MARKER'
        try:
            open(sys.argv[1]).read()
        except PermissionError:
            pass
        else:
            raise AssertionError('owner OpenCode auth readable')
        """
        let result = try U34Support.python(root, profile: U34Support.profile(root, harness: "opencode"),
            code: code, arguments: [auth.path], environment: prepared)
        #expect(result.0 == 0, "\(result)")
        #expect(try String(contentsOf: auth, encoding: .utf8) == "OWNER_LOGIN_MARKER")
    }

    // Acceptance 6: an accepted request without a reply differs from absent/refused listeners.
    @Test func brokerClientDistinguishesNoAnswerFromNotRunning() async throws {
        let fixture = try BrokerHome()
        let home = try AgencilHome(directory: fixture.url, environment: [:])
        let client = BrokerClient(home: home)
        let absent = "Agencil is not running (open the app or run agencil serve)"
        U40Support.expectFailure(client, message: absent)
        let listener = try UnixSocket.listen(at: home.socketPath)
        do {
            defer { close(listener) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Thread.detachNewThread {
                    do {
                        try U40Support.acceptAndClose(listener)
                        shutdown(listener, SHUT_RDWR)
                        continuation.resume()
                    } catch {
                        // Release a queued client if the fixture cannot accept it.
                        shutdown(listener, SHUT_RDWR)
                        continuation.resume(throwing: error)
                    }
                }
                U40Support.expectFailure(client, message:
                    "Agencil took the request but gave no answer (try again; if it repeats, quit and reopen Agencil)")
            }
        }
        // The socket path remains, but no listener owns it (ECONNREFUSED).
        U40Support.expectFailure(client, message: absent)
    }

    // Acceptance 7: a linked seed folder must not redirect an owner credential read.
    @Test(arguments: ["opencode", "codex"])
    func prepareRejectsLinkedSeedFolders(harness: String) throws {
        let fixture = try BrokerHome(), root = fixture.url
        let home = URL(fileURLWithPath: U34Support.testHome(root)), fm = FileManager.default
        let run = root.appendingPathComponent("run")
        let outside = root.appendingPathComponent("outside-seeds")
        let original = try U34Support.bytes(U34Support.login())
        try U34Support.put(outside.appendingPathComponent("auth.json"), original)
        let relative = harness == "opencode" ? ".local/share/opencode" : ".codex"
        let link = home.appendingPathComponent(relative)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try Data(contentsOf: link.appendingPathComponent("auth.json")) == original)
        #expect(SafeRead.ownerFile(home: home.path, relative: relative + "/auth.json", limit: 32 << 20) == nil)
        let prepared = try #require(try SeatHome.prepare(harness: harness, runDirectory: run, home: home.path))
        let target = harness == "opencode" ? "home/data/opencode/auth.json" : "home/.codex/auth.json"
        #expect(prepared == (harness == "opencode" ? U40Support.environment(run) :
            ["CODEX_HOME": run.appendingPathComponent("home/.codex").path]))
        #expect((try? fm.attributesOfItem(atPath: run.appendingPathComponent(target).path)) == nil)
        #expect(try Data(contentsOf: outside.appendingPathComponent("auth.json")) == original)
    }

    // Acceptance 8: only regular files within the inclusive limit are readable; a FIFO cannot hang the read.
    @Test func safeReadRejectsUnsafeFilesAndHonorsInclusiveLimit() throws {
        let fixture = try BrokerHome(), root = fixture.url, fm = FileManager.default
        let regular = root.appendingPathComponent("regular")
        let bytes = Data(repeating: 0x61, count: SafeRead.outputLimit)
        try U34Support.put(regular, bytes)
        #expect(SafeRead.file(regular.path) == bytes)
        let link = root.appendingPathComponent("linked-file")
        try fm.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(try Data(contentsOf: link) == bytes)
        #expect(SafeRead.file(link.path) == nil)
        #expect(SafeRead.file(root.path) == nil)
        try U34Support.put(regular, bytes + Data([0x62]))
        #expect(SafeRead.file(regular.path) == nil)
        try U34Support.put(regular, Data("abcd".utf8))
        #expect(SafeRead.file(regular.path, limit: 4) == Data("abcd".utf8))
        #expect(SafeRead.file(regular.path, limit: 3) == nil)

        let fifo = root.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            #expect(SafeRead.file(fifo.path) == nil)
            finished.signal()
        }
        // clock-wait: bound a blocking-open regression; the correct read returns without a writer.
        let result = finished.wait(timeout: .now() + 5)
        #expect(result == .success, "SafeRead.file blocked on a FIFO without a writer")
        if result == .timedOut {
            // Release a regressed blocking open so it does not leave a worker stuck after this test.
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            // clock-wait: let the released reader finish before the fixture is removed.
            #expect(finished.wait(timeout: .now() + 5) == .success)
        }
    }

    // Acceptance 9: a successful seat exit cannot make the broker follow an answer link.
    @Test(.enabled(if: U34Support.sandboxAvailable, "sandbox-exec cannot apply a profile in this environment"))
    func confinedBrokerAskRejectsAnswerLinkWithoutLeakingTarget() throws {
        let rig = try U6dRig()
        let outside = rig.fakeHome.appendingPathComponent(".ssh/id_ed25519")
        let marker = "U40_OUTSIDE_ANSWER_SECRET"
        try U34Support.put(outside, marker)
        let stub = rig.base.bin.appendingPathComponent("codex")
        let script = try String(contentsOf: stub, encoding: .utf8)
        let anchor = "if [ -n \"$output\" ]; then printf 'u6a answer' > \"$output\"; else printf 'u6a answer'; fi"
        try #require(script.contains(anchor))
        let replacement = """
        [ -n "$output" ] || exit 71
        /bin/rm -f "$output" || exit 72
        /bin/ln -s "$HOME/.ssh/id_ed25519" "$output" || exit 73
        exit 0
        """
        try script.replacingOccurrences(of: anchor, with: replacement)
            .write(to: stub, atomically: false, encoding: .utf8)
        try rig.repository()
        let reply = try rig.base.data(rig.ask())
        #expect(reply["state"] as? String == "failed")
        #expect(reply["reason"] as? String == "codex answered nothing")
        #expect(!(reply["answer"] as? String ?? "").contains(marker))
        let cwd = URL(fileURLWithPath: try rig.observation(".cwd").trimmingCharacters(in: .whitespacesAndNewlines))
        let run = cwd.deletingLastPathComponent()
        #expect(U34Support.resolved(run).hasPrefix(U34Support.resolved(rig.home.url.appendingPathComponent("runs")) + "/"))
        #expect(!U34Support.resolved(outside).hasPrefix(U34Support.resolved(run) + "/"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath:
            run.appendingPathComponent("answer.txt").path) == outside.path)
        #expect(try rig.budget.sql("SELECT exit_status FROM launches;") == "0\n")
        #expect(try rig.budget.sql("SELECT count(*) FROM exchanges;") == "1\n")
        #expect(try rig.budget.sql("SELECT state, reason FROM exchanges;") == "failed|codex answered nothing\n")
        #expect(!(try rig.budget.sql("SELECT answer FROM exchanges;")).contains(marker))
        #expect(try String(contentsOf: outside, encoding: .utf8) == marker)
    }

    // Acceptance 10: measure before thread exit can drain autoreleased FileHandles.
    @Test func detachedProcessCallsDoNotLeakDescriptors() async throws {
        let counts = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Int, Int), any Error>) in
            Thread.detachNewThread {
                do {
                    let nonce = UUID().uuidString
                    // Warm up Foundation's process machinery before the measured calls.
                    guard ProcessTable.launchers(nonce: nonce) != nil,
                          RepoCopy.output(["--version"])?.hasPrefix("git version ") == true else {
                        throw BrokerFailure("Could not warm up ps and git")
                    }
                    let before = U40Support.descriptorCount()
                    // No autoreleasepool here: the broker's detached threads do not drain one.
                    for _ in 0..<200 {
                        guard ProcessTable.launchers(nonce: nonce) != nil,
                              RepoCopy.output(["--version"])?.hasPrefix("git version ") == true else {
                            throw BrokerFailure("A measured ps or git call failed")
                        }
                    }
                    let after = U40Support.descriptorCount()
                    continuation.resume(returning: (before, after))
                } catch { continuation.resume(throwing: error) }
            }
        }
        #expect(abs(counts.1 - counts.0) <= 2, "Open descriptors before: \(counts.0), after: \(counts.1)")
    }
}

private enum U40Support {
    static func environment(_ run: URL) -> [String: String] {
        ["XDG_DATA_HOME": run.appendingPathComponent("home/data").path,
         "XDG_STATE_HOME": run.appendingPathComponent("home/state").path,
         "XDG_CACHE_HOME": run.appendingPathComponent("home/cache").path]
    }

    static func descriptorCount() -> Int {
        (0..<4096).reduce(0) { count, fd in count + (fcntl(Int32(fd), F_GETFD) >= 0 ? 1 : 0) }
    }

    static func expectFailure(_ client: BrokerClient, message: String) {
        do {
            _ = try client.send(["op": "ping"])
            Issue.record("Expected broker client failure")
        } catch let failure as BrokerClient.Failure {
            #expect(failure.exit == 3)
            #expect(failure.message == message)
        } catch { Issue.record("Unexpected broker client error: \(error)") }
    }

    static func acceptAndClose(_ listener: Int32) throws {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        // clock-wait: bound the real socket handshake; successful requests do not wait for the timeout.
        guard poll(&ready, 1, 5_000) == 1 else { throw BrokerFailure("No client reached the test listener") }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { throw BrokerFailure("Test listener could not accept") }
        defer { close(connection) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                        socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw BrokerFailure("Could not bound the request read")
        }
        // Drain the request before closing so the client observes EOF, not a write race.
        guard case .line(let request) = UnixSocket.Reader(descriptor: connection).next(),
              try brokerJSON(request)["op"] as? String == "ping" else {
            throw BrokerFailure("Test listener did not receive a complete request")
        }
    }
}
