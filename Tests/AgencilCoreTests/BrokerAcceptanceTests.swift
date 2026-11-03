import Foundation
import Darwin
import Testing

@Suite struct BrokerAcceptanceTests {
    @Test func everyClientRefusesWithoutBroker() throws {
        let home = try BrokerHome()
        let brief = home.url.appendingPathComponent("brief")
        try "change_kind: docs\nquestion: Review the guide\n".write(to: brief, atomically: true, encoding: .utf8)
        let commands = [["ask", "reviewer", "Review"], ["result", "t1"],
                        ["wake", "review", "--brief", brief.path], ["status", "t1"], ["stop", "t1"],
                        ["seats"], ["councils"], ["routes"], ["harnesses"], ["models"],
                        ["findings"], ["dispose", "c1", "confirm"], ["leaderboard", "preview"]]
        for command in commands {
            let (code, _, error) = try home.cli(command)
            #expect(code == 3, "\(command)")
            #expect(error == "agencil: Agencil is not running (open the app or run agencil serve)\n")
        }
    }

    @Test func versionAndUsageHaveDocumentedExitCodes() throws {
        let home = try BrokerHome()
        let (code, version, _) = try home.cli(["version"])
        #expect(code == 0)
        #expect(version.hasPrefix("agencil "))
        #expect(version.split(separator: " ").count >= 2)
        for command in [["version", "--bad-flag"], ["wake", "review"]] {
            let (status, _, error) = try home.cli(command)
            #expect(status == 64)
            #expect(error.hasPrefix("agencil:"))
        }
        // U5 cannot produce 1 (BLOCK), 2 (pending/INCOMPLETE), or 4 (seat failure).
    }

    @Test func internalStorageFailureExits70() throws {
        let home = try BrokerHome()
        let file = home.url.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: file)
        let p = try BrokerProcess(["serve"], home: home.url, env: ["AGENCIL_HOME": file.path])
        let (code, _, error) = try p.finish()
        #expect(code == 70)
        #expect(error.hasPrefix("agencil:"))
    }

    @Test func askAndWakeRefuseAbsentRoutes() throws {
        let home = try BrokerHome(), broker = try home.serve()
        defer { broker.kill() }
        let brief = home.url.appendingPathComponent("brief")
        try "change_kind: docs\nquestion: Review the guide\n".write(to: brief, atomically: true, encoding: .utf8)
        for args in [["ask", "reviewer", "Review"], ["wake", "review", "--brief", brief.path]] {
            let (code, _, error) = try home.cli(args)
            #expect(code == 3)
            #expect(error.hasPrefix("agencil: refused: no route "))
        }
    }

    @Test func configurationClientsReturnVersionedEnvelopes() throws {
        let home = try BrokerHome(), broker = try home.serve()
        defer { broker.kill() }
        for verb in ["seats", "councils", "routes", "harnesses", "models"] {
            let (code, output, _) = try home.cli([verb, "--json"])
            #expect(code == 0)
            let envelope = try brokerJSON(Data(output.utf8))
            #expect(envelope["api"] as? Int == 1)
            #expect(envelope["source"] as? String == "agencil")
            #expect(envelope["generated_at"] as? String != nil)
            #expect(envelope["data_note"] as? String != nil)
            #expect(envelope["data"] != nil)
        }
    }

    @Test func privateSocketExclusiveLockAndGracefulRestart() throws {
        let home = try BrokerHome(), first = try home.serve()
        defer { first.kill() }
        for (path, mode) in [(home.url.path, 0o700), (home.url.appendingPathComponent("agencil.sock").path, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("broker.lock").path))
        let second = try BrokerProcess(["serve"], home: home.url)
        let (code, out, error) = try second.finish()
        #expect(code != 0)
        #expect(!(out + error).isEmpty)
        #expect(first.process.isRunning)
        first.kill(SIGTERM)
        _ = try first.finish()
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("agencil.sock").path))
        let next = try home.serve()
        defer { next.kill() }
        #expect(try home.request(["op": "ping"])["ok"] as? Bool == true)
    }

    @Test func staleSocketIsRecoveredAfterSIGKILL() throws {
        let home = try BrokerHome(), first = try home.serve()
        first.kill(); _ = try first.finish()
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("agencil.sock").path))
        let next = try home.serve()
        defer { next.kill() }
        #expect(try home.request(["op": "ping"])["ok"] as? Bool == true)
    }

    @Test func simultaneousBrokersHaveExactlyOneWinnerTenTimes() throws {
        for _ in 0..<10 {
            let home = try BrokerHome()
            let first = try BrokerProcess(["serve"], home: home.url)
            let second = try BrokerProcess(["serve"], home: home.url)
            defer { first.kill(); second.kill() }
            try brokerPoll { first.process.isRunning != second.process.isRunning }
            let loser = first.process.isRunning ? second : first
            let winner = first.process.isRunning ? first : second
            let (code, out, error) = try loser.finish()
            #expect(code != 0 && code < 128)
            #expect(loser.process.terminationReason == .exit)
            #expect(!(out + error).isEmpty)
            try brokerPoll { (try? home.request(["op": "ping"])["ok"] as? Bool) == true }
            #expect(winner.process.isRunning)
        }
    }

    @Test func socketPeerPIDIsTheActualClientPID() throws {
        let home = try BrokerHome(), broker = try home.serve()
        defer { broker.kill() }
        // This test process itself is the tiny Darwin socket client.
        #expect(try brokerInt(home.request(["op": "ping"]), "peer_pid") == getpid())
    }

    @Test func launcherRegistersIdentityBeforeExecInSamePIDAndOwnGroup() throws {
        let home = try BrokerHome(), broker = try home.serve()
        defer { broker.kill() }
        let launch = try home.launch(), pid = try brokerInt(launch, "pid")
        defer { brokerGroupCleanup(pid) }
        #expect(launch["ok"] as? Bool == true)
        #expect(try brokerInt(launch, "pgid") == pid)
        let run = try #require(launch["run"] as? String)
        try brokerPoll { (try? home.marker().count) == 3 }
        let marker = try home.marker(), status = try home.status(run)
        #expect(Int32(marker[0]) == pid)
        #expect(try brokerInt(status, "pid") == pid)
        #expect(try brokerInt(status, "pgid") == pid)
        let registered = try #require(status["registered_at"] as? Double)
        #expect(registered < (Double(marker[1]) ?? 0))
        #expect(status["start_time"] as? Double != nil)
        #expect(status["reserved"] as? Bool == true)
        #expect(getpgid(pid) == pid)
        _ = try home.request(["op": "stop", "run": run])
        try brokerPoll { !brokerAlive(pid) }
        try brokerPoll { try home.status(run)["reserved"] as? Bool == false }
    }

    @Test func restartKillsOrphanChildBeforeReleasingReservation() throws {
        try recovery(mode: "orphan", hold: false)
    }

    @Test func termIgnoringChildKeepsReservationUntilLastMemberDies() throws {
        try recovery(mode: "stubborn", hold: true)
    }

    private func recovery(mode: String, hold: Bool) throws {
        let home = try BrokerHome(), first = try home.serve()
        defer { first.kill() }
        let launch = try home.launch(mode, extra: ["CHILD_READY": home.url.appendingPathComponent("ready").path])
        let pid = try brokerInt(launch, "pid"), run = try #require(launch["run"] as? String)
        defer { brokerGroupCleanup(pid) }
        try brokerPoll { (try? home.marker().count) == 3 }
        let child = try #require(Int32(home.marker()[2]))
        if mode == "orphan" { try brokerPoll { !brokerAlive(pid) } }
        #expect(brokerAlive(child))
        #expect(try home.status(run)["reserved"] as? Bool == true)
        first.kill(); _ = try first.finish()
        let next = try home.serve(hold ? ["AGENCIL_TEST_RECOVERY_HOLD": "1"] : [:])
        defer { next.kill() }
        if hold {
            // Repeated observations must not see released capacity while the child is alive.
            for _ in 0..<20 {
                #expect(brokerAlive(child))
                let state = try home.status(run)
                #expect(state["reserved"] as? Bool == true)
                #expect(state["state"] as? String != "interrupted")
                usleep(10_000)
            }
            Darwin.kill(-pid, SIGKILL)
        }
        try brokerPoll { !brokerAlive(pid) && !brokerAlive(child) }
        try brokerPoll {
            let state = try home.status(run)
            return state["state"] as? String == "interrupted" && state["reserved"] as? Bool == false
        }
    }

    @Test func crashBeforeRegistrationFindsNonceAndNeverExecsSeat() throws {
        let home = try BrokerHome(), first = try home.serve(["AGENCIL_TEST_PAUSE_AFTER_SPAWN": "1"])
        defer { first.kill() }
        // A separate process sends launch so the paused response cannot block the test.
        // Dispatch owns only this socket call; the broker's death unblocks it.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { defer { group.leave() }; _ = try? home.launch() }
        let spawned = home.url.appendingPathComponent("test-spawn.json")
        try brokerPoll { FileManager.default.fileExists(atPath: spawned.path) }
        let intent = try brokerJSON(Data(contentsOf: spawned)), pid = try brokerInt(intent, "pid")
        defer { brokerGroupCleanup(pid) }
        let run = try #require(intent["run"] as? String), nonce = try #require(intent["nonce"] as? String)
        let (_, argv) = try acceptanceCommand(["/bin/ps", "-p", String(pid), "-o", "command="])
        #expect(argv.contains("run-seat " + nonce))
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("marker").path))
        first.kill(); _ = try first.finish()
        #expect(group.wait(timeout: .now() + 30) == .success)
        let next = try home.serve()
        defer { next.kill() }
        try brokerPoll { !brokerAlive(pid) }
        let status = try home.status(run)
        #expect(status["state"] as? String == "interrupted")
        #expect(status["reserved"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("marker").path))
    }

    @Test func matchingStartTimeIsKilledOnRecovery() throws {
        try recovery(mode: "leader", hold: false)
    }

    @Test func mismatchedStartTimeNeverSignalsTheRecordedPID() throws {
        let home = try BrokerHome(), first = try home.serve(["AGENCIL_TEST_FORGE_START_TIME": "1"])
        defer { first.kill() }
        // A real sleep stands in for an unrelated process that reused the recorded PID.
        let launch = try home.request(["op": "launch", "argv": ["/bin/sleep", "120"],
                                       "cwd": home.url.path, "env": [:], "reservation": ["seconds": 120]])
        let pid = try brokerInt(launch, "pid")
        defer { brokerGroupCleanup(pid) }
        #expect(brokerAlive(pid))
        first.kill(); _ = try first.finish()
        let next = try home.serve()
        defer { next.kill() }
        for _ in 0..<20 { #expect(brokerAlive(pid)); usleep(10_000) }
    }
}
