import Darwin
import Foundation

/// `ask`, `result`, thread status and stop: one-seat councils on top of the launch machinery.
extension Broker {
    private static let fileLimit = 64 * 1024
    private static let defaultWait = 120

    func ask(_ request: [String: Any]) -> [String: Any] {
        let socketCaller = request["caller"] as? String ?? "unknown"
        // Only the owner's CLI may speak as someone else; any other connection is who it says it is.
        let caller = socketCaller == "owner" ? (request["as"] as? String ?? "owner") : socketCaller
        guard let target = request["target"] as? String, let question = request["question"] as? String else {
            return Self.failure("ask needs a target and a question", exit: 64)
        }
        func settle(_ refusal: Refusal) -> [String: Any] {
            try? threads.recordRequest(caller: caller, outcome: refusal.exit == 3 ? "refused" : "failed")
            return Self.failure(refusal.message, exit: refusal.exit)
        }
        do {
            let config: SeatConfig
            do { config = try SeatConfig(values: try ConfigStore(directory: directory).read().values) } catch let problem as ConfigProblem {
                return settle(Refusal(exit: 4, message: problem.message))
            }
            let files = try readFiles(request["files"])
            let world = discovery.world(environment: environment, home: directory)
            var existing: ThreadRecord?
            var resolved: Resolved
            if let id = request["thread"] as? String {
                guard let thread = try threads.thread(id: id) else { throw Failure(message: "unknown id \(id)") }
                guard [thread.seat, thread.requested].contains(target) else {
                    throw Failure(message: "a follow-up goes to the thread's seat \(thread.seat)")
                }
                guard let route = config.route(from: caller, to: thread.requested) else {
                    return settle(Refusal(exit: 3, message: "refused: no route from \(caller) to \(target)"))
                }
                guard let seat = config.seat(named: thread.seat) else {
                    return settle(Refusal(exit: 4, message: "failed: seat \(thread.seat) is no longer configured"))
                }
                switch Resolver.usable(seat, world) {
                case .success(let executable): resolved = Resolved(seat: seat, route: route, substituted: thread.substituted, executable: executable)
                case .failure(let problem): return settle(Refusal(exit: 4, message: "failed: \(problem.reason)"))
                }
                existing = thread
            } else {
                resolved = try Resolver.resolve(config: config, caller: caller, target: target, world: world)
            }
            return try run(resolved, caller: caller, requested: target, question: question, files: files,
                           thread: existing, wait: waitSeconds(request))
        } catch let refusal as Refusal {
            return settle(refusal)
        } catch let failure as Failure {
            try? threads.recordRequest(caller: caller, outcome: "failed")
            return Self.failure(failure.message, exit: 64)
        } catch {
            return Self.failure(error.localizedDescription, exit: 70)
        }
    }

    func result(_ request: [String: Any]) -> [String: Any]? {
        guard let id = request["id"] as? String, id.hasPrefix("th_"), let thread = try? threads.thread(id: id),
              let latest = (try? threads.exchanges(thread: id))?.last else { return nil }
        return reply(thread, awaiting: latest.seq, wait: waitSeconds(request, fallback: 0))
    }

    func threadStatus(_ id: String) throws -> [String: Any] {
        guard let thread = try threads.thread(id: id), let latest = try threads.exchanges(thread: id).last else {
            throw Failure(message: "unknown id \(id)")
        }
        return ["ok": true, "data": ["thread": id, "seat": thread.seat, "state": Self.stateName(latest.state), "exchanges": try threads.exchanges(thread: id).count]]
    }

    func stopThread(_ id: String) throws -> [String: Any] {
        guard try threads.thread(id: id) != nil, let latest = try threads.exchanges(thread: id).last else {
            throw Failure(message: "unknown id \(id)")
        }
        guard latest.state == .asking else { return ["ok": true, "run": id, "stopping": false] }
        let key = "\(id)-\(latest.seq)"
        tracking.withLock {
            stoppedThreads.insert(key)
            ollamaTasks[key]?.cancel()
        }
        if latest.launchID == nil { return ["ok": true, "run": id, "stopping": true] }
        if let launch = latest.launchID, let run = tracking.withLock({ tracked[launch] }) { terminate(run) }
        return ["ok": true, "run": id, "stopping": true]
    }

    // MARK: running one exchange

    private func run(_ resolved: Resolved, caller: String, requested: String, question: String,
                     files: [(path: String, text: String)], thread existing: ThreadRecord?, wait: Int) throws -> [String: Any] {
        let thread = try existing ?? threads.createThread(requested: requested, seat: resolved.seat.name, caller: caller,
                                                         substituted: resolved.substituted)
        guard let (exchange, transcript) = try threads.beginExchange(thread: thread.id, question: question) else {
            throw Failure(message: "thread \(thread.id) is still waiting for an answer")
        }
        let key = "\(thread.id)-\(exchange.seq)"
        do {
            try threads.recordRequest(caller: caller, outcome: "accepted", runID: thread.id)
            let prompt = Adapter.prompt(question: question, files: files, transcript: transcript)
            let runDirectory = directory.appendingPathComponent("runs").appendingPathComponent("\(thread.id)-\(exchange.seq)")
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let answerFile = runDirectory.appendingPathComponent("answer.txt").path
            let seat = resolved.seat

            func fail(_ reason: String) -> [String: Any] {
                try? threads.finish(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil, reason: reason)
                return reply(thread, awaiting: exchange.seq, wait: 0)
            }
            if seat.harness == "ollama" {
                Thread.detachNewThread { [self] in
                    let result = OllamaClient.chat(seat: seat, prompt: prompt) { task in
                        tracking.withLock {
                            ollamaTasks[key] = task
                            if stoppedThreads.contains(key) { task.cancel() }
                        }
                    }
                    let stopped = tracking.withLock { () -> Bool in
                        ollamaTasks[key] = nil
                        return stoppedThreads.remove(key) != nil
                    }
                    if stopped {
                        try? threads.finish(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil, reason: "stopped")
                        return
                    }
                    switch result {
                    case .success(let text): try? threads.finish(thread: thread.id, seq: exchange.seq, state: .answered, answer: text, reason: nil)
                    case .failure(let refusal): try? threads.finish(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil,
                                                                     reason: String(refusal.message.dropFirst("failed: ".count)))
                    }
                }
                return reply(thread, awaiting: exchange.seq, wait: wait)
            }
            guard let executable = resolved.executable,
                  let invocation = try Adapter.command(seat: seat, executable: executable, prompt: prompt, answerFile: answerFile,
                                                       runDirectory: runDirectory.path) else {
                return fail("\(seat.harness) has no adapter")
            }
            let workingDirectory = invocation.workingDirectory ?? runDirectory.path
            // A shell reports $PWD as inherited when it names the working directory, so it must match the path we gave.
            var launchRequest: [String: Any] = ["argv": invocation.argv, "cwd": workingDirectory,
                                                "env": invocation.environment.merging(["PWD": workingDirectory]) { _, mine in mine },
                                                "reservation": ["seconds": seat.capSeconds]]
            if invocation.stdoutIsAnswer { launchRequest["stdout"] = answerFile }
            let began = Date()
            let started: [String: Any]
            // The exchange is tied to its launch before the seat can start, so a crash never orphans a running group.
            var attached: String?
            do {
                started = try launch(launchRequest, onIntent: { id in
                    try self.threads.attach(launch: id, thread: thread.id, seq: exchange.seq)
                    attached = id
                })
            } catch {
                if let id = attached { failWhenClosed(thread: thread.id, seq: exchange.seq, launch: id, reason: "the seat could not be started: \(error.localizedDescription)") }
                else { try? threads.finish(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil, reason: "the seat could not be started") }
                return reply(thread, awaiting: exchange.seq, wait: 0)
            }
            guard let launchID = started["run"] as? String else { return fail("the seat could not be started") }
            // A stop that arrived before the launch was attached found nothing to end; end it now.
            if tracking.withLock({ stoppedThreads.contains(key) }), let run = tracking.withLock({ tracked[launchID] }) { terminate(run) }
            Thread.detachNewThread { [self] in complete(thread: thread, seq: exchange.seq, launchID: launchID, answerFile: answerFile, seat: seat, began: began) }
            return reply(thread, awaiting: exchange.seq, wait: wait)
        } catch {
            // Setup failed before any seat ran: the exchange must not stay asking and block every follow-up.
            try? threads.finish(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil,
                                reason: "the seat could not be set up: \(error.localizedDescription)")
            throw error
        }
    }

    /// Waits for the seat's leader to exit, ends whatever it left in the group, and records what it answered.
    private func complete(thread: ThreadRecord, seq: Int, launchID: String, answerFile: String, seat: Seat, began: Date) {
        var status: Int32?
        var ranFor = 0.0
        while true {
            if let run = tracking.withLock({ tracked[launchID] }) {
                if let leader = run.leaderStatus {
                    status = leader
                    ranFor = Date().timeIntervalSince(began)
                    terminate(run)
                    // The exchange stays asking (and stoppable) until the monitor has seen the group empty.
                    while tracking.withLock({ tracked[launchID] }) != nil { usleep(20_000) }
                    break
                }
            } else {
                status = (try? store.launch(id: launchID))?.exitStatus
                ranFor = Date().timeIntervalSince(began)
                break
            }
            usleep(20_000)
        }
        let stopped = tracking.withLock { stoppedThreads.remove("\(thread.id)-\(seq)") != nil }
        if stopped {
            try? threads.finish(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "stopped")
        } else if ranFor >= Double(seat.capSeconds) {
            try? threads.finish(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "\(seat.harness) ran past its \(seat.capSeconds) second cap")
        } else if status == 0 {
            let text = ((try? String(contentsOfFile: answerFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                try? threads.finish(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "\(seat.harness) answered nothing")
            } else {
                try? threads.finish(thread: thread.id, seq: seq, state: .answered, answer: text, reason: nil)
            }
        } else {
            let detail = lastLine(ofLog: launchID).map { ": \($0)" } ?? ""
            let code = status.map { "status \($0)" } ?? "an unknown status"
            try? threads.finish(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "\(seat.harness) exited with \(code)\(detail)")
        }
    }

    private func lastLine(ofLog launchID: String) -> String? {
        let log = directory.appendingPathComponent("runs/\(launchID).log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map { String($0.prefix(200)) }
    }

    // MARK: replies

    private func reply(_ thread: ThreadRecord, awaiting seq: Int, wait: Int) -> [String: Any] {
        let deadline = Date().addingTimeInterval(Double(wait))
        var exchange = (try? threads.exchanges(thread: thread.id))?.first { $0.seq == seq }
        while exchange?.state == .asking, Date() < deadline {
            usleep(20_000)
            exchange = (try? threads.exchanges(thread: thread.id))?.first { $0.seq == seq }
        }
        var data: [String: Any] = ["thread": thread.id, "seat": thread.seat, "substituted": thread.substituted ?? NSNull(),
                                   "state": Self.stateName(exchange?.state ?? .asking)]
        if let answer = exchange?.answer { data["answer"] = answer }
        if let reason = exchange?.reason { data["reason"] = reason }
        return ["ok": true, "data": data]
    }

    private static func stateName(_ state: Exchange.State) -> String {
        state == .asking ? "pending" : state.rawValue
    }

    private func waitSeconds(_ request: [String: Any], fallback: Int = defaultWait) -> Int {
        min(max(request["wait_seconds"] as? Int ?? fallback, 0), 3600)
    }

    private func readFiles(_ value: Any?) throws -> [(path: String, text: String)] {
        guard let paths = value as? [String] else { return [] }
        return try paths.map { path in
            guard path.hasPrefix("/"), let data = FileManager.default.contents(atPath: path) else {
                throw Failure(message: "cannot read \(path)")
            }
            var text = String(decoding: data.prefix(Self.fileLimit), as: UTF8.self)
            if data.count > Self.fileLimit { text += "\n[truncated: cut at 64 KB]" }
            return (path, text)
        }
    }
}

extension Broker {
    /// Exchanges that were asking when a broker died: each fails once its launch is proven closed, never before,
    /// so a follow-up cannot start while the old process group is still alive. An exchange with no recorded launch
    /// waits for every launch that was open at startup.
    func reconcileExchanges() {
        guard let open = try? threads.unfinished(), !open.isEmpty else { return }
        let startup = Set(((try? store.open()) ?? []).map(\.id))
        Thread.detachNewThread { [self] in
            for item in open {
                let waitFor = item.launchID.map { [$0] } ?? Array(startup)
                waitUntilClosed(waitFor)
                try? threads.finish(thread: item.thread, seq: item.seq, state: .failed, answer: nil,
                                    reason: "the broker restarted before the seat answered")
            }
        }
    }

    /// Fails the exchange only after the launch's group is proven empty.
    func failWhenClosed(thread: String, seq: Int, launch: String, reason: String) {
        Thread.detachNewThread { [self] in
            waitUntilClosed([launch])
            try? threads.finish(thread: thread, seq: seq, state: .failed, answer: nil, reason: reason)
        }
    }

    private func waitUntilClosed(_ launches: [String]) {
        // An unreadable ledger keeps waiting: ownership is never released on an unknown state.
        while true {
            if let open = try? store.open(), !open.contains(where: { launches.contains($0.id) }) { return }
            sleep(1)
        }
    }
}
