import Darwin
import Foundation

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
}

/// The one way Agencil starts a program: argv only (no shell), its own process group, stdin closed, a PATH
/// built per program, and a deadline that is a failure even when the program exits 0 on TERM.
public struct ProcessRunner: Sendable {
    public enum Failure: Error, Equatable {
        case timedOut
        case outputLimit
        case waitFailed(Int32)
        case spawnFailed(String)
    }

    private static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Captured stdout and stderr together; a program that writes more is stopped like one that overran its time.
    private static let outputLimit = 64 * 1024 * 1024

    public init() {}

    /// `log` is called with the argv before anything is spawned. On timeout the group gets TERM, then KILL
    /// after `gracePeriod`; a group that outlived its leader gets KILL too.
    public func run(
        _ argv: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        timeout: Duration,
        gracePeriod: Duration,
        log: @Sendable ([String]) -> Void = { _ in }
    ) async throws -> ProcessOutput {
        guard let program = argv.first else { throw Failure.spawnFailed("empty argv") }
        log(argv)
        var env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let executable = try Self.resolve(program, path: env["PATH"] ?? Self.defaultPath)
        env["PATH"] = Self.path(for: executable, base: env["PATH"] ?? Self.defaultPath)

        // One clock and one deadline for the whole wait: `mach_absolute_time`, awake time, the clock the kernel records
        // a child's exit on. Computed before the spawn, so nothing after it can trap.
        let budget = Self.ticks(timeout)
        let spawnedAt = mach_absolute_time()
        let child = try Self.spawn(executable: executable, argv: argv, environment: env, directory: directory)
        defer { close(child.stdout); close(child.stderr) }
        var out = Data(), err = Data()
        func drain() {
            Self.drain(child.stdout, into: &out)
            Self.drain(child.stderr, into: &err)
        }
        func overLimit() -> Bool { out.count + err.count > Self.outputLimit }

        // While `owned`, the child (a zombie once it exits) still holds its pid and process group, so signalling
        // the group cannot hit a recycled id. Everything that reaps it clears the flag.
        var owned = true
        do {
            let (sum, wrapped) = spawnedAt.addingReportingOverflow(budget)
            let deadline = wrapped ? UInt64.max : sum
            exitWait: while true {
                try Task.checkCancellation()
                drain()
                switch Self.liveness(child.pid) {
                case .exited:
                    // Judged by when the kernel says the child exited, not when this poll ran: a starved poll can run
                    // seconds late, and must neither turn a timely exit into a timeout nor let a late one through.
                    // Without a trusted record, the moment of this poll stands in for the exit.
                    if (Self.exitTime(child.pid, spawnedAt: spawnedAt) ?? mach_absolute_time()) < deadline { break exitWait }
                case .lost(let code): throw Failure.waitFailed(code)
                case .running: break
                }
                if overLimit() || mach_absolute_time() >= deadline {
                    let limited = overLimit()
                    try await Self.terminate(child.pid, gracePeriod: gracePeriod)
                    owned = false
                    try Task.checkCancellation()
                    throw limited ? Failure.outputLimit : Failure.timedOut
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            // The group belongs to this run: whatever the leader left behind goes with it, before the leader is reaped.
            Self.killAll(child.pid)
            drain()
            let status = Self.reap(child.pid)
            owned = false
            try Task.checkCancellation()
            guard let status else { throw Failure.waitFailed(ECHILD) }
            if overLimit() { throw Failure.outputLimit }
            return ProcessOutput(status: Self.exitCode(status), stdout: out, stderr: String(decoding: err, as: UTF8.self))
        } catch {
            // A lost wait means the child is no longer ours to signal: its ids may belong to someone else now.
            if case Failure.waitFailed = error { owned = false }
            if owned {
                Self.killAll(child.pid)
                _ = Self.reap(child.pid)
            }
            throw error
        }
    }

    /// TERM the group, wait out the grace period for the leader, then KILL whatever is left of the group, and reap.
    private static func terminate(_ pid: pid_t, gracePeriod: Duration) async throws {
        killpg(pid, SIGTERM)
        let deadline = ContinuousClock.now + gracePeriod
        while ContinuousClock.now < deadline {
            switch liveness(pid) {
            case .running: break
            case .exited: killAll(pid); _ = reap(pid); return
            case .lost(let code): throw Failure.waitFailed(code)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        killAll(pid)
        _ = reap(pid)
    }

    /// When the unreaped child exited, on this process's `mach_absolute_time`. Nil when the record cannot be trusted:
    /// the call failed, or the child's own start time is not on this clock (a Rosetta process sees a rescaled clock
    /// while the kernel keeps native ticks). Then the poll's own clock decides.
    private static func exitTime(_ pid: pid_t, spawnedAt: UInt64) -> UInt64? {
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard read == 0, usage.ri_proc_start_abstime >= spawnedAt, usage.ri_proc_exit_abstime >= usage.ri_proc_start_abstime,
              usage.ri_proc_exit_abstime <= mach_absolute_time() else { return nil }
        return usage.ri_proc_exit_abstime
    }

    /// `duration` in `mach_absolute_time` ticks, rounded down, exact: ticks = (s * 10^18 + as) * denom / (numer * 10^9),
    /// in 128-bit steps. A negative duration is 0; only a result past the clock's range saturates to `UInt64.max`.
    private static func ticks(_ duration: Duration) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0, attoseconds >= 0, timebase.numer > 0 else { return 0 }
        let numer = UInt64(timebase.numer), denom = UInt64(timebase.denom), billion: UInt64 = 1_000_000_000
        // Whole seconds: s * 10^9 * denom / numer, with the remainder carried in units of 1/numer tick.
        let scaledSeconds = UInt64(seconds).multipliedFullWidth(by: billion * denom)
        guard scaledSeconds.high < numer else { return .max }
        let (secondTicks, carried) = numer.dividingFullWidth(scaledSeconds)
        // The rest: (carried * 10^9 + as * denom) / (numer * 10^9), below 1 + denom ticks.
        let scaledRest = UInt64(attoseconds).multipliedFullWidth(by: denom)
        let (low, carry) = scaledRest.low.addingReportingOverflow(carried * billion)
        let (restTicks, _) = (numer * billion).dividingFullWidth((scaledRest.high + (carry ? 1 : 0), low))
        let (total, overflow) = secondTicks.addingReportingOverflow(restTicks)
        return overflow ? .max : total
    }

    /// KILL for the leader itself (it may have left its group) and for the rest of the group. Called only while
    /// the leader is unreaped, so neither id can have been recycled.
    private static func killAll(_ pid: pid_t) {
        kill(pid, SIGKILL)
        killpg(pid, SIGKILL)
    }

    private enum Liveness {
        case running
        case exited
        /// waitid failed: the exit state is unknown, which is never reported as success.
        case lost(Int32)
    }

    /// Looks without reaping (WNOWAIT), so the pid stays reserved while the group is signalled.
    private static func liveness(_ pid: pid_t) -> Liveness {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                return info.si_pid == pid ? .exited : .running
            }
            if errno != EINTR { return .lost(errno) }
        }
    }

    /// Blocks until the child is collected; nil when it cannot be (ECHILD). An interrupted wait is retried.
    private static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            if waitpid(pid, &status, 0) == pid { return status }
            if errno != EINTR { return nil }
        }
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func resolve(_ program: String, path: String) throws -> String {
        if program.contains("/") { return program }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(program)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw Failure.spawnFailed("\(program) not found on PATH")
    }

    /// The program's own directory first, so a tool finds the helpers installed beside it: an npm harness
    /// (`#!/usr/bin/env node`) must run on the node it was installed with, not the first one on PATH.
    static func path(for executable: String, base: String) -> String {
        let own = (executable as NSString).deletingLastPathComponent
        let rest = base.split(separator: ":").map(String.init).filter { $0 != own }
        return ([own.isEmpty ? "." : own] + rest).joined(separator: ":")
    }

    private static func spawn(executable: String, argv: [String], environment: [String: String], directory: URL?)
        throws -> (pid: pid_t, stdout: Int32, stderr: Int32) {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw Failure.spawnFailed("pipe failed") }
        guard pipe(&errPipe) == 0 else {
            outPipe.forEach { close($0) }
            throw Failure.spawnFailed("pipe failed")
        }
        for descriptor in [outPipe[0], errPipe[0]] { _ = fcntl(descriptor, F_SETFL, O_NONBLOCK) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func setup(_ code: Int32, _ step: String) throws {
            guard code == 0 else {
                (outPipe + errPipe).forEach { close($0) }
                throw Failure.spawnFailed("\(step): \(String(cString: strerror(code)))")
            }
        }
        try setup(posix_spawn_file_actions_init(&actions), "file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try setup(posix_spawnattr_init(&attributes), "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try setup(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0), "stdin")
        try setup(posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1), "stdout")
        try setup(posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2), "stderr")
        if let directory { try setup(posix_spawn_file_actions_addchdir_np(&actions, directory.path), "working directory") }
        // Every descriptor but 0, 1 and 2 is closed in the child, so a concurrent run's pipe ends never leak into it.
        try setup(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)), "flags")
        try setup(posix_spawnattr_setpgroup(&attributes, 0), "process group")

        let argvC = argv.map { strdup($0) } + [nil]
        let envC = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argvC + envC { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argvC, envC)
        close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw Failure.spawnFailed("\(executable): \(String(cString: strerror(result)))")
        }
        return (pid, outPipe[0], errPipe[0])
    }

    /// At most 256 KiB per call, so a chatty child cannot starve the deadline and cancellation checks.
    private static func drain(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<4 {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(buffer, count: count)
        }
    }
}
