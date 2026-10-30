// API contract: ProcessRunner().run(_ argv: [String], in directory: URL? = nil,
// environment: [String: String] = [:], timeout: Duration, gracePeriod: Duration,
// log: @Sendable ([String]) -> Void = { _ in }) async throws -> ProcessOutput.
// ProcessOutput exposes status: Int32, stdout: Data, stderr: String.
// Timeout throws ProcessRunner.Failure.timedOut (Equatable), including a TERM exit 0.
// log is synchronous and precedes spawn. The executable's directory leads its PATH.
import Foundation
import Darwin
import Testing
import AgencilCore

@Suite struct ProcessAcceptanceTests {
    @Test(.timeLimit(.minutes(1))) func timeoutKillsIgnoringChildAndGrandchildAfterGrace() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let pids = temp.url.appendingPathComponent("pids")
        let script = "trap '' TERM; /bin/sleep 30 & child=$!; printf '%s %s' \"$$\" \"$child\" > \"$1\"; wait"
        let start = ContinuousClock.now
        defer {
            // Test cleanup also applies if a broken runner leaves descendants alive.
            if let text = try? String(contentsOf: pids, encoding: .utf8) {
                for pid in text.split(separator: " ").compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
            }
        }
        do {
            _ = try await ProcessRunner().run(["/bin/sh", "-c", script, "fixture", pids.path],
                                              timeout: .milliseconds(700), gracePeriod: .milliseconds(300))
            Issue.record("Timeout returned success")
        } catch { #expect((error as? ProcessRunner.Failure) == .timedOut) }
        let elapsed = start.duration(to: .now)
        #expect(elapsed >= .milliseconds(950), "Ignoring TERM must survive until the grace deadline")
        #expect(elapsed < .seconds(5))
        let text = try String(contentsOf: pids, encoding: .utf8)
        let identifiers = text.split(separator: " ").compactMap { Int32($0) }
        try #require(identifiers.count == 2)
        #expect(identifiers[0] != identifiers[1])
        let deadline = ContinuousClock.now + .seconds(2)
        while identifiers.contains(where: { kill($0, 0) == 0 }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        for pid in identifiers {
            #expect(kill(pid, 0) == -1 && errno == ESRCH, "Process \(pid) survived timeout")
        }
    }

    @Test func termHandlerExitingZeroStillReportsTimeout() async throws {
        do {
            _ = try await ProcessRunner().run(
                ["/bin/sh", "-c", "trap 'exit 0' TERM; while :; do :; done"],
                timeout: .milliseconds(200), gracePeriod: .milliseconds(100))
            Issue.record("Deadline was incorrectly converted to success by exit 0")
        } catch { #expect((error as? ProcessRunner.Failure) == .timedOut) }
    }

    @Test func commandIsLoggedBeforeChildRunsAndStdinIsEOF() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let marker = temp.url.appendingPathComponent("logged")
        let argv = ["/bin/sh", "-c", "test -f \"$1\" || exit 17; if read line; then exit 18; fi; printf ready",
                    "fixture", marker.path]
        let result = try await ProcessRunner().run(argv, timeout: .seconds(2), gracePeriod: .milliseconds(100),
                                                 log: { logged in
            #expect(logged == argv)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            do { try Data("logged".utf8).write(to: marker) }
            catch { Issue.record("Log sink failed: \(error)") }
        })
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "ready")
        #expect(result.stderr.isEmpty)
        #expect(try Data(contentsOf: marker) == Data("logged".utf8))
    }

    @Test func argvIsLiteralAndExecutableDirectoryLeadsPath() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let executable = temp.url.appendingPathComponent("fixture")
        let helper = temp.url.appendingPathComponent("neighbor")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$1\"\nneighbor\n".utf8).write(to: executable)
        try Data("#!/bin/sh\nprintf neighbor-ok\n".utf8).write(to: helper)
        for file in [executable, helper] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let literal = "$(touch forbidden); * ' quoted"
        let result = try await ProcessRunner().run([executable.path, literal], in: temp.url,
                                                  environment: ["PATH": "/usr/bin:/bin"],
                                                  timeout: .seconds(2), gracePeriod: .milliseconds(100))
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == literal + "\nneighbor-ok")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("forbidden").path))
    }
}
