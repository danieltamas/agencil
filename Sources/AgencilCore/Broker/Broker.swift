import Darwin
import Foundation

/// The one process per Mac that owns the ledger and every seat process. It holds `broker.lock` for its whole
/// life, serves JSON lines on `agencil.sock`, and reconciles whatever a dead predecessor left running.
public final class Broker: @unchecked Sendable {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Set in every seat's environment so a process can later be shown to belong to its run.
    static let runMarker = "AGENCIL_RUN"
    public static let note = "Agencil 0.1: seats, routes and councils arrive with U6; launches and recovery are live."

    let directory: URL
    let environment: [String: String]
    let ledger: Ledger
    let store: LaunchStore
    let socketPath: String
    /// The `agencil` CLI that seats are launched through: this process in `serve`, the bundled CLI inside the app.
    let launcherExecutable: String?
    private let lockDescriptor: Int32
    private let connectionLimit = 64
    private let idleSeconds = 30
    private var listener: Int32 = -1
    let tracking = NSLock()
    var tracked: [String: TrackedRun] = [:]
    var waiting: [String: PendingLaunch] = [:]
    private var connections = 0

    /// Takes the exclusive lock first: only the holder may remove a stale socket or touch the ledger's runs.
    public init(home: AgencilHome, environment: [String: String], launcherExecutable: String? = nil) throws {
        directory = home.directory
        self.launcherExecutable = launcherExecutable
        self.environment = environment
        socketPath = directory.appendingPathComponent("agencil.sock").path
        let descriptor = open(directory.appendingPathComponent("broker.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure(message: "cannot open broker.lock: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure(message: "another Agencil broker is already serving")
        }
        lockDescriptor = descriptor
        do { ledger = try Ledger(directory: directory) } catch {
            close(descriptor)
            throw error
        }
        store = LaunchStore(ledger: ledger)
    }

    deinit { close(lockDescriptor) }

    /// Reconciles the dead predecessor's launches, then serves on a background thread. Returns once listening.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { [self] in monitorLoop() }
        recoverOpenLaunches()
        unlink(socketPath)
        listener = try UnixSocket.listen(at: socketPath)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// The headless broker: serves until SIGTERM or SIGINT; never returns normally.
    public func serve() throws -> Never {
        try start()
        let path = socketPath
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { unlink(path); exit(0) }
            source.resume()
            sources.append(source)
        }
        dispatchMain()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // A silent client may not hold a thread forever, and there is a ceiling on how many it may hold.
            var timeout = timeval(tv_sec: idleSeconds, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let admitted = tracking.withLock { () -> Bool in
                guard connections < connectionLimit else { return false }
                connections += 1
                return true
            }
            guard admitted else { close(client); continue }
            Thread.detachNewThread { [self] in
                connection(client)
                tracking.withLock { connections -= 1 }
            }
        }
    }

    private func connection(_ descriptor: Int32) {
        defer { close(descriptor) }
        let peer = UnixSocket.peerPID(descriptor)
        let reader = UnixSocket.Reader(descriptor: descriptor)
        while true {
            switch reader.next() {
            case .end: return
            case .tooLong:
                UnixSocket.write(descriptor, line: UnixSocket.json(Self.failure("request line too long", exit: 64)))
            case .line(let data):
                guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let op = request["op"] as? String else {
                    UnixSocket.write(descriptor, line: UnixSocket.json(Self.failure("malformed request", exit: 64)))
                    continue
                }
                let response = handle(op, request, peer: peer)
                let delivered = UnixSocket.write(descriptor, line: UnixSocket.json(response))
                if op == "register", response["go"] as? Bool == true, let nonce = request["nonce"] as? String {
                    releaseLaunch(nonce: nonce, delivered: delivered)
                }
                if !delivered { return }
            }
        }
    }

    private func handle(_ op: String, _ request: [String: Any], peer: Int32?) -> [String: Any] {
        do {
            switch op {
            case "ping":
                return ["ok": true, "peer_pid": peer.map { Int($0) } ?? NSNull(), "version": AgencilVersion.current()]
            case "register": return try register(request, peer: peer)
            case "launch":
                try? store.recordRequest(peer: peer)
                return try launch(request)
            case "status": return try status(request)
            case "stop": return try stop(request)
            case "ask", "wake":
                try? store.recordRequest(peer: peer)
                let target = (request["target"] as? String) ?? (request["council"] as? String) ?? "?"
                return Self.failure("refused: no route from \(peer.map { "pid \($0)" } ?? "unknown caller") to \(target)", exit: 3)
            case "result", "dispose":
                return Self.failure("unknown id \((request["id"] as? String) ?? "?")", exit: 64)
            case "seats", "councils", "routes", "harnesses", "models", "findings", "leaderboard", "list_targets":
                return ["ok": true, "data": [op: [Any]()], "data_note": Self.note]
            default:
                return Self.failure("unknown op \(op)", exit: 64)
            }
        } catch let error as Failure {
            return Self.failure(error.message, exit: 64)
        } catch {
            return Self.failure("\(error.localizedDescription)", exit: 70)
        }
    }

    static func failure(_ message: String, exit: Int) -> [String: Any] {
        ["ok": false, "error": message, "exit": exit]
    }

    private func status(_ request: [String: Any]) throws -> [String: Any] {
        guard let id = request["run"] as? String ?? request["id"] as? String,
              let launch = try store.launch(id: id) else {
            throw Failure(message: "unknown id \((request["run"] as? String) ?? (request["id"] as? String) ?? "?")")
        }
        var response: [String: Any] = ["ok": true, "run": launch.id, "state": launch.state == .intent ? "running" : launch.state.rawValue,
                                       "reserved": launch.reserved]
        if let pid = launch.pid { response["pid"] = Int(pid) }
        if let pgid = launch.pgid { response["pgid"] = Int(pgid) }
        if let start = launch.startTime { response["start_time"] = start }
        if let at = launch.registeredAt { response["registered_at"] = at }
        return response
    }
}
