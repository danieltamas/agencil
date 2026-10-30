import Darwin
import Foundation

/// A launch the broker is watching until its process group is proven empty.
final class TrackedRun: @unchecked Sendable {
    let id: String
    let pid: Int32
    let pgid: Int32
    let spawnedHere: Bool
    let recovered: Bool
    /// Test seam: after TERM never escalate to KILL, so a test can observe the reservation held.
    let hold: Bool
    let deadline: Double
    /// A process belongs to this run only if it started inside this window: after the leader, and before the
    /// reservation ran out plus the time to kill it. A reused pid or group id starts outside it.
    let window: ClosedRange<Double>
    var termSentAt: Double?
    private let recordedStart: Double
    private var proven: Set<Int32> = []

    init(id: String, pid: Int32, pgid: Int32, spawnedHere: Bool, recovered: Bool, hold: Bool,
         startTime: Double, reservedSeconds: Int) {
        self.id = id; self.pid = pid; self.pgid = pgid; self.spawnedHere = spawnedHere
        self.recovered = recovered; self.hold = hold
        recordedStart = startTime
        deadline = startTime + Double(reservedSeconds)
        window = (startTime - 0.5)...(startTime + Double(reservedSeconds) + 30)
    }

    /// The members of the group that are this run's. Nil when the kernel could not be asked. A process counts
    /// when it started inside the window and is either the recorded leader or carries this run's marker (the
    /// broker put it in the seat's environment). A readable environment without the marker is a reused group id.
    func members() -> [ProcessTable.Entry]? {
        ProcessTable.members(ofGroup: pgid)?.filter { member in
            guard window.contains(member.startTime) else { return false }
            if member.pid == pid && abs(member.startTime - recordedStart) < 0.5 { return true }
            if proven.contains(member.pid) { return true }
            // An environment we can read must carry the marker; one we cannot read counts (fail closed).
            if let environment = ProcessTable.environment(of: member.pid), environment[Broker.runMarker] != id { return false }
            proven.insert(member.pid)
            return true
        }
    }
}

/// A launcher that was spawned and has not yet reported its identity.
final class PendingLaunch: @unchecked Sendable {
    var pid: Int32 = 0
    let spawned = DispatchSemaphore(value: 0)
    let registered = DispatchSemaphore(value: 0)
    /// Whether `go` reached the launcher: the launch is only reported once the harness is certain to exec.
    var released = false
}

extension Broker {
    private static let grace = 2.0
    private static let registrationTimeout = 10.0

    private var seamPause: Bool { environment["AGENCIL_TEST_PAUSE_AFTER_SPAWN"] == "1" }

    /// Records the launcher's intent, spawns it, and answers once its identity is in the ledger.
    func launch(_ request: [String: Any]) throws -> [String: Any] {
        guard let argv = request["argv"] as? [String], !argv.isEmpty else { throw Failure(message: "launch needs an argv") }
        let reservation = (request["reservation"] as? [String: Any])?["seconds"] as? Int ?? 0
        guard reservation > 0 else { throw Failure(message: "launch needs a reservation in seconds") }
        let launch = try store.createIntent(argv: argv, cwd: request["cwd"] as? String ?? directory.path,
                                            env: request["env"] as? [String: String] ?? [:], reservedSeconds: reservation)
        let pending = PendingLaunch()
        tracking.withLock { waiting[launch.nonce] = pending }
        defer { tracking.withLock { _ = waiting.removeValue(forKey: launch.nonce) } }

        let pid: Int32
        do { pid = try spawnLauncher(launch) } catch {
            try? store.finish(id: launch.id, state: .interrupted)
            throw error
        }
        pending.pid = pid
        if seamPause {
            let note = ["run": launch.id, "pid": Int(pid), "pgid": Int(pid), "nonce": launch.nonce] as [String: Any]
            try? UnixSocket.json(note).write(to: directory.appendingPathComponent("test-spawn.json"))
            while true { sleep(3600) }
        }
        pending.spawned.signal()
        guard pending.registered.wait(timeout: .now() + Self.registrationTimeout) == .success else {
            // A registration may have committed just now: then the monitor owns the group and ends it. Otherwise
            // the launcher never got `go`, and the run ends once its group is proven empty.
            if let run = tracking.withLock({ tracked[launch.id] }) {
                terminate(run)
            } else {
                killpg(pid, SIGKILL); kill(pid, SIGKILL)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                if ProcessTable.members(ofGroup: pid)?.isEmpty == true { try? store.finish(id: launch.id, state: .interrupted) }
            }
            throw Failure(message: "the seat launcher did not register")
        }
        guard pending.released else {
            try? store.finish(id: launch.id, state: .interrupted)
            throw Failure(message: "the seat launcher was not released")
        }
        return ["ok": true, "run": launch.id, "pid": Int(pid), "pgid": Int(pid)]
    }

    /// Called once the reply to a `register` request has been written (or failed): unblocks the waiting launch.
    func releaseLaunch(nonce: String, delivered: Bool) {
        guard let pending = tracking.withLock({ waiting[nonce] }) else { return }
        pending.released = delivered
        pending.registered.signal()
    }

    /// The launcher's first message: its identity is recorded, and only then is it told to exec the harness.
    func register(_ request: [String: Any], peer: Int32?) throws -> [String: Any] {
        guard let nonce = request["nonce"] as? String,
              let pending = tracking.withLock({ waiting[nonce] }) else { throw Failure(message: "no launch is waiting for that nonce") }
        if seamPause { while true { sleep(3600) } }
        guard pending.spawned.wait(timeout: .now() + 5) == .success else { throw Failure(message: "launcher raced its own spawn") }
        let pid = pending.pid
        guard peer == pid, getpgid(pid) == pid, var start = ProcessTable.startTime(of: pid),
              let launch = try store.launch(nonce: nonce) else { throw Failure(message: "launcher identity does not match its spawn") }
        if environment["AGENCIL_TEST_FORGE_START_TIME"] != nil { start = 1 }
        let at = try store.register(id: launch.id, pid: pid, pgid: pid, startTime: start)
        let run = TrackedRun(id: launch.id, pid: pid, pgid: pid, spawnedHere: true, recovered: false, hold: false,
                             startTime: start, reservedSeconds: launch.reservedSeconds)
        _ = at
        tracking.withLock { tracked[launch.id] = run }
        var env = environment.filter { !$0.key.hasPrefix("AGENCIL_TEST_") }
        env.merge(launch.env) { _, new in new }
        env[Self.runMarker] = launch.id
        return ["ok": true, "go": true, "argv": launch.argv, "cwd": launch.cwd, "env": env]
    }

    func stop(_ request: [String: Any]) throws -> [String: Any] {
        guard let id = request["run"] as? String ?? request["id"] as? String,
              let launch = try store.launch(id: id) else { throw Failure(message: "unknown id") }
        if let run = tracking.withLock({ tracked[id] }) { terminate(run) }
        return ["ok": true, "run": launch.id, "stopping": launch.reserved]
    }

    private func terminate(_ run: TrackedRun) {
        guard run.termSentAt == nil else { return }
        run.termSentAt = Date().timeIntervalSince1970
        killpg(run.pgid, SIGTERM)
    }

    private func spawnLauncher(_ launch: Launch) throws -> Int32 {
        guard let executable = launcherExecutable ?? Bundle.main.executablePath ?? CommandLine.arguments.first else {
            throw Failure(message: "cannot locate the Agencil executable")
        }
        let logs = directory.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = logs.appendingPathComponent("\(launch.id).log").path
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        // Own process group from birth, and no descriptor but 0-2 (the lock and the socket stay with the broker).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = [executable, "run-seat", launch.nonce]
        var env = environment.filter { !$0.key.hasPrefix("AGENCIL_TEST_") }
        env["AGENCIL_HOME"] = directory.path
        let argvC = argv.map { strdup($0) } + [nil]
        let envC = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argvC + envC { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argvC, envC)
        guard result == 0 else { throw Failure(message: "cannot start the seat launcher: \(String(cString: strerror(result)))") }
        return pid
    }

    // MARK: watching

    func monitorLoop() {
        while true {
            usleep(50_000)
            for run in tracking.withLock({ Array(tracked.values) }) { watch(run) }
        }
    }

    /// A run ends, and its reservation is released, only when no process remains in its group.
    private func watch(_ run: TrackedRun) {
        if run.spawnedHere {
            var status: Int32 = 0
            waitpid(run.pid, &status, WNOHANG)
        }
        // A failed look is not an empty group: the run stays reserved until the kernel answers.
        guard let members = run.members() else { return }
        if members.isEmpty {
            do { try store.finish(id: run.id, state: run.recovered ? .interrupted : .exited) } catch { return }
            tracking.withLock { _ = tracked.removeValue(forKey: run.id) }
            return
        }
        let now = Date().timeIntervalSince1970
        if run.termSentAt == nil, run.recovered || now > run.deadline { terminate(run) }
        if let sent = run.termSentAt, now - sent > Self.grace, !run.hold { killpg(run.pgid, SIGKILL) }
    }

    // MARK: recovery

    /// Reconciles every launch a dead predecessor left open. The decisions are made before the socket serves, so a
    /// client never reads a stale `running`; only the wait for a group to empty continues in the monitor.
    func recoverOpenLaunches() {
        var unresolved: [Launch] = []
        for launch in (try? store.open()) ?? [] {
            if launch.pid == nil {
                if !settleUnregistered(launch, attempts: 30) { unresolved.append(launch) }
            } else { adopt(launch) }
        }
        guard !unresolved.isEmpty else { return }
        Thread.detachNewThread { [self] in
            for launch in unresolved { _ = settleUnregistered(launch, attempts: .max) }
        }
    }

    /// A launcher that died or hung before registering: found by its nonce, killed, never allowed to exec.
    /// An unreadable process list leaves the reservation held.
    private func settleUnregistered(_ launch: Launch, attempts: Int) -> Bool {
        var remaining = attempts
        while remaining > 0 {
            if let found = ProcessTable.launchers(nonce: launch.nonce) {
                if found.isEmpty { try? store.finish(id: launch.id, state: .interrupted); return true }
                for process in found {
                    kill(process.pid, SIGKILL)
                    if process.pgid == process.pid { killpg(process.pgid, SIGKILL) }
                }
            }
            usleep(100_000)
            remaining -= 1
        }
        return false
    }

    /// A recorded group is signalled only through its members that started inside the run's window; with none
    /// of those, nothing is ours to signal and the run ends. An unreadable process table keeps the reservation held.
    private func adopt(_ launch: Launch) {
        guard let pid = launch.pid, let pgid = launch.pgid, let recorded = launch.startTime else {
            try? store.finish(id: launch.id, state: .interrupted)
            return
        }
        let run = TrackedRun(id: launch.id, pid: pid, pgid: pgid, spawnedHere: false, recovered: true,
                             hold: environment["AGENCIL_TEST_RECOVERY_HOLD"] == "1",
                             startTime: recorded, reservedSeconds: launch.reservedSeconds)
        guard let ours = run.members() else {
            tracking.withLock { tracked[launch.id] = run }
            return
        }
        guard !ours.isEmpty else { try? store.finish(id: launch.id, state: .interrupted); return }
        tracking.withLock { tracked[launch.id] = run }
        terminate(run)
    }
}
