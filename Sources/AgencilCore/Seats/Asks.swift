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
        tracking.withLock { _ = stoppedThreads.insert(id) }
        if latest.launchID == nil { return ["ok": true, "run": id, "stopping": true] }
        if let launch = latest.launchID, let run = tracking.withLock({ tracked[launch] }) { terminate(run) }
        return ["ok": true, "run": id, "stopping": true]
    }

    // MARK: running one exchange

    private func run(_ resolved: Resolved, caller: String, requested: String, question: String,
                     files: [(path: String, text: String)], thread existing: ThreadRecord?, wait: Int) throws -> [String: Any] {
        let thread = try existing ?? threads.createThread(requested: requested, seat: resolved.seat.name, caller: caller,
                                                         substituted: resolved.substituted)
        if existing != nil, try threads.exchanges(thread: thread.id).contains(where: { $0.state == .asking }) {
            throw Failure(message: "thread \(thread.id) is still waiting for an answer")
        }
        try threads.recordRequest(caller: caller, outcome: "accepted", runID: thread.id)
        let transcript = try threads.exchanges(thread: thread.id).filter { $0.state == .answered }
            .map { (asked: $0.question, answered: $0.answer ?? "") }
        let exchange = try threads.addExchange(thread: thread.id, question: question)
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
                let result = OllamaClient.chat(seat: seat, prompt: prompt)
                if tracking.withLock({ stoppedThreads.remove(thread.id) != nil }) {
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
        let started: [String: Any]
        do { started = try launch(launchRequest) } catch { return fail("the seat could not be started: \(error.localizedDescription)") }
        guard let launchID = started["run"] as? String else { return fail("the seat could not be started") }
        try threads.attach(launch: launchID, thread: thread.id, seq: exchange.seq)
        // A stop that arrived before the launch was attached found nothing to end; end it now.
        if tracking.withLock({ stoppedThreads.contains(thread.id) }), let run = tracking.withLock({ tracked[launchID] }) { terminate(run) }
        Thread.detachNewThread { [self] in complete(thread: thread, seq: exchange.seq, launchID: launchID, answerFile: answerFile, seat: seat) }
        return reply(thread, awaiting: exchange.seq, wait: wait)
    }

    /// Waits for the seat's leader to exit, ends whatever it left in the group, and records what it answered.
    private func complete(thread: ThreadRecord, seq: Int, launchID: String, answerFile: String, seat: Seat) {
        var status: Int32?
        let began = Date()
        while true {
            if let run = tracking.withLock({ tracked[launchID] }) {
                if let leader = run.leaderStatus {
                    status = leader
                    terminate(run)
                    break
                }
            } else {
                status = (try? store.launch(id: launchID))?.exitStatus
                break
            }
            usleep(20_000)
        }
        let stopped = tracking.withLock { stoppedThreads.remove(thread.id) != nil }
        if stopped {
            try? threads.finish(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "stopped")
        } else if Date().timeIntervalSince(began) >= Double(seat.capSeconds) {
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
