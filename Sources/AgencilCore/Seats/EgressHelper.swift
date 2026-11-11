import Darwin
import Foundation

/// `agencil egress-proxy <harness>`: the process that owns a harness's egress proxy (docs/U38-SPEC.md). A seat's
/// profile names a loopback port, not a listener, and a seat can outlive the broker, so the port must never fall free
/// while a seat might still run: the proxy lives in this process of its own, which outlives the broker.
public enum EgressHelper {
    /// What a broker needs to reuse a running helper. It sits in the Agencil home, which only the owner can write, so
    /// a record is the owner's word; the start time tells the helper from a later process with its pid.
    struct Record: Codable, Equatable {
        let pid: Int32
        let startTime: Double
        let port: Int
        let hosts: [String]
    }

    static func recordFile(home: URL, harness: String) -> URL { home.appendingPathComponent("egress-\(harness).json") }

    private static func record(at file: URL) -> Record? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    /// The helper serving exactly `hosts`, when the process its record names is still that process.
    static func running(home: URL, harness: String, hosts: Set<String>) -> Record? {
        guard let found = record(at: recordFile(home: home, harness: harness)), found.hosts == hosts.sorted(),
              (1...65535).contains(found.port), ProcessTable.startTime(of: found.pid) == found.startTime else { return nil }
        return found
    }

    /// Serves until its record is removed, which only the owner can do (an uninstall, or a test's home being deleted).
    /// A newer helper that replaces the record does not end this one: seats started on this port may still run.
    public static func run(harness: String, home: AgencilHome) -> Int32 {
        // Room for every socket the proxy may hold, whatever limit the helper inherited.
        var descriptors = rlimit()
        if getrlimit(RLIMIT_NOFILE, &descriptors) == 0, descriptors.rlim_cur < 1024 {
            descriptors.rlim_cur = min(1024, descriptors.rlim_max)
            setrlimit(RLIMIT_NOFILE, &descriptors)
        }
        guard let hosts = Egress.hosts(for: harness), let startTime = ProcessTable.startTime(of: getpid()),
              let proxy = try? EgressProxy(allowedHosts: hosts) else { return 1 }
        // Quitting the app or closing a terminal must not free the port; an uninstall removes the record instead.
        for number in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] { signal(number, SIG_IGN) }
        let file = recordFile(home: home.directory, harness: harness)
        let staged = file.appendingPathExtension("\(getpid())")
        let record = Record(pid: getpid(), startTime: startTime, port: proxy.port, hosts: hosts.sorted())
        guard let encoded = try? JSONEncoder().encode(record),
              FileManager.default.createFile(atPath: staged.path, contents: encoded, attributes: [.posixPermissions: 0o600]),
              rename(staged.path, file.path) == 0 else {
            unlink(staged.path)
            return 1
        }
        while FileManager.default.fileExists(atPath: file.path) { sleep(2) }
        proxy.stop()
        return 0
    }
}

extension Broker {
    /// The port of the harness's egress proxy, from the running helper or one started now; nil for a harness that is
    /// not proxied. No helper means the ask is refused: the seat is never given open network instead.
    func egressPort(for harness: String) throws -> Int? {
        guard let hosts = Egress.hosts(for: harness) else { return nil }
        let unavailable = Refusal(exit: 4, message: "failed: confinement unavailable")
        return try egressLock.withLock {
            if let running = EgressHelper.running(home: directory, harness: harness, hosts: hosts) { return running.port }
            guard let pid = spawnEgressHelper(harness) else { throw unavailable }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let started = EgressHelper.running(home: directory, harness: harness, hosts: hosts), started.pid == pid { return started.port }
                usleep(20_000)
            }
            throw unavailable
        }
    }

    private func spawnEgressHelper(_ harness: String) -> pid_t? {
        guard let executable = launcherExecutable ?? Bundle.main.executablePath ?? CommandLine.arguments.first else { return nil }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        for descriptor in Int32(0)...2 { posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0) }
        // Its own session and none of the broker's descriptors: nothing ties its life to the broker's.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [String] = [executable, "egress-proxy", harness]
        var env = environment.filter { !$0.key.hasPrefix("AGENCIL_TEST_") }
        env["AGENCIL_HOME"] = directory.path
        let argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let envC: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argvC + envC { free(pointer) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, argvC, envC) == 0 else { return nil }
        // A helper that ends while this broker lives is reaped, so it does not linger as a zombie.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return pid
    }
}
