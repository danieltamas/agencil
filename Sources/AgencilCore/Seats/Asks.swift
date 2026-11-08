import Darwin
import Foundation

/// `ask`, `result`, thread status and stop: one-seat councils on top of the launch machinery.
extension Broker {
    private static let fileLimit = 64 * 1024
    private static let defaultWait = 120

    func ask(_ request: [String: Any], peer: Int32?, peerStart: Double?) -> [String: Any] {
        let socketCaller = request["caller"] as? String ?? "unknown"
        let origin: Origin
        switch attribute(peer: peer, peerStart: peerStart, capability: request["cap"] as? String) {
        case .failure(let refusal):
            try? threads.recordRequest(caller: socketCaller, outcome: "refused")
            return Self.failure(refusal.message, exit: refusal.exit)
        case .success(let found): origin = found
        }
        // A seat's child is the seat that started it, whatever it claims. Only a root's owner CLI may speak as
        // someone else; any other root connection is who it says it is.
        let parent: CapabilityRun?
        if case .child(let run) = origin { parent = run } else { parent = nil }
        let caller = parent?.seat ?? (socketCaller == "owner" ? (request["as"] as? String ?? "owner") : socketCaller)
        let parentChain = parent?.chain ?? []
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
            let kinds = parent.flatMap { config.seat(named: $0.seat)?.harness }.map { [$0] } ?? []
            let policy = parent != nil || socketCaller != "owner" ? try attachPolicy(request, peer: peer) : nil
            let files = try AttachedFiles.read(request["files"], policy: policy)
            let repo = try repository(request["repo"])
            let world = resolverWorld()
            var existing: ThreadRecord?
            var resolved: Resolved
            var prompt = Adapter.prompt(question: question, files: files, transcript: [])
            // Budgets match the route the thread was opened through, whichever name a follow-up uses.
            var routeKey = target
            func admit(_ seat: Seat, _ route: Route) throws -> Admitted {
                if let refusal = Placement.refusal(seat: seat, route: route, hasRepo: repo != nil) { throw refusal }
                return try self.admit(seat, requested: routeKey, caller: caller, parent: parent, prompt: prompt, config: config)
            }
            if let id = request["thread"] as? String {
                guard let thread = try threads.thread(id: id) else { throw Failure(message: "unknown id \(id)") }
                guard [thread.seat, thread.requested].contains(target) else {
                    throw Failure(message: "a follow-up goes to the thread's seat \(thread.seat)")
                }
                guard let route = config.route(from: [caller] + kinds, to: thread.requested) else {
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
                routeKey = thread.requested
                prompt = Adapter.prompt(question: question, files: files, transcript: try threads.transcript(thread: thread.id))
            } else {
                resolved = try Resolver.resolve(config: config, caller: caller, alsoKnownAs: kinds, target: target, world: world, admit: admit)
            }
            do {
                if existing != nil { resolved.admitted = try admit(resolved.seat, resolved.route) }
                // The cycle comes first: a seat already in the chain is refused at any hop limit.
                if parentChain.contains(resolved.seat.name) {
                    throw Refusal(exit: 3, message: "refused: cycle " + (parentChain + [resolved.seat.name]).joined(separator: " -> "))
                }
                if parentChain.count > resolved.route.hopLimit { throw Refusal(exit: 3, message: "refused: hop limit") }
                if repo != nil {
                    if resolved.seat.harness == "ollama" { throw Refusal(exit: 4, message: "failed: ollama seats cannot read a repo") }
                    _ = try Confinement.executable(environment: environment)
                }
                // A follow-up keeps the chain its thread started with, whoever asks it.
                let chain = try existing.flatMap { try threads.exchanges(thread: $0.id).first?.chain } ?? parentChain + [resolved.seat.name]
                // A seat may only continue a thread that already sits at its own place in the chain.
                if existing != nil, parent != nil, chain != parentChain + [resolved.seat.name] {
                    throw Refusal(exit: 3, message: "refused: ancestry unknown")
                }
                return try run(resolved, caller: caller, chain: chain, parent: parent, requested: target, question: question, files: files,
                               repo: repo, thread: existing, limits: config.limits, wait: waitSeconds(request),
                               project: ProjectLabel.clean(request["project"]))
            } catch {
                if let held = resolved.admitted { abandon(held) }
                throw error
            }
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

    func run(_ resolved: Resolved, caller: String, chain: [String], parent: CapabilityRun?, requested: String, question: String,
                     files: [(path: String, text: String)], images: [AttachedImage] = [], repo: String?, thread existing: ThreadRecord?, limits: Limits,
                     wait: Int, placeWait: Int? = nil, snapshot: Snapshot? = nil, verbatim: Bool = false, project: String? = nil,
                     sittingRound: (sitting: String, round: String)? = nil,
                     isOver: () -> Bool = { false }) throws -> [String: Any] {
        guard let admitted = resolved.admitted else { throw Failure(message: "the ask was not admitted") }
        try awaitSeat(admitted, limits: limits, wait: placeWait ?? wait, cancelled: isOver)
        let thread = try existing ?? threads.createThread(requested: requested, seat: resolved.seat.name, caller: caller,
                                                         substituted: resolved.substituted, project: project, sittingRound: sittingRound)
        guard let (exchange, transcript) = try threads.beginExchange(thread: thread.id, question: question, chain: chain) else {
            throw Failure(message: "thread \(thread.id) is still waiting for an answer")
        }
        try threads.recordIdentity(thread: thread.id, seq: exchange.seq, harness: resolved.seat.harness, model: resolved.seat.model)
        let key = "\(thread.id)-\(exchange.seq)"
        capacity.bind(admitted.id, exchange: key)
        do {
            // The reservation is tied to the exchange before anything runs, or nothing runs.
            try budgets.bind(admitted.id, thread: thread.id, seq: exchange.seq)
            try threads.recordRequest(caller: caller, outcome: "accepted", runID: thread.id)
            // A follow-up that waited for a place may now repeat more than the reservation was sized for.
            let actual = Self.quote(resolved.seat, prompt: Adapter.prompt(question: question, files: files, transcript: transcript, verbatim: verbatim))
            if actual.tokens > admitted.quote.tokens || actual.dollars > admitted.quote.dollars {
                finishExchange(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil,
                               reason: "the thread changed while the ask waited for a place; ask again")
                return reply(thread, awaiting: exchange.seq, wait: 0)
            }
            let runDirectory = directory.appendingPathComponent("runs").appendingPathComponent("\(thread.id)-\(exchange.seq)")
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let answerFile = runDirectory.appendingPathComponent("answer.txt").path
            let seat = resolved.seat
            let packet = try packet(seat: seat, runDirectory: runDirectory, repo: repo, question: question, files: files, transcript: transcript,
                                snapshot: snapshot, verbatim: verbatim, images: images)
            let prompt = packet.prompt

            func fail(_ reason: String) -> [String: Any] {
                finishExchange(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil, reason: reason)
                return reply(thread, awaiting: exchange.seq, wait: 0)
            }
            if seat.harness == "ollama" {
                if let parent, (try? threads.capability(launch: parent.launchID))??.live != true { return fail("refused: capability expired") }
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
                        finishExchange(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil, reason: "stopped")
                        return
                    }
                    switch result {
                    case .success(let answer):
                        let spent = answer.tokens.map { counts in
                            (dollars: Double(counts.prompt) / 1e6 * seat.price.inputPerMillion + Double(counts.output) / 1e6 * seat.price.outputPerMillion,
                             tokens: counts.prompt + counts.output)
                        }
                        finishExchange(thread: thread.id, seq: exchange.seq, state: .answered, answer: answer.text, reason: nil, usage: spent)
                    case .failure(let refusal):
                        finishExchange(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil,
                                       reason: String(refusal.message.dropFirst("failed: ".count)))
                    }
                }
                return reply(thread, awaiting: exchange.seq, wait: wait)
            }
            guard let executable = resolved.executable,
                  var invocation = try Adapter.command(seat: seat, executable: executable, prompt: prompt, answerFile: answerFile,
                                                       runDirectory: runDirectory.path, reportUsage: true, images: packet.imagePaths) else {
                return fail("\(seat.harness) has no adapter")
            }
            if seat.harness == "opencode" {
                // A stop of the thread or of its sitting ends the wait, and nothing is launched after one.
                func stopped() -> Bool { isOver() || tracking.withLock { stoppedThreads.contains(key) } }
                if !holdOpencode(exchange: key, wait: placeWait ?? wait, cancelled: stopped) { return fail(stopped() ? "stopped" : "refused: busy") }
                if stopped() { return fail("stopped") }
            }
            var workingDirectory = invocation.workingDirectory ?? runDirectory.path
            if let copy = packet.copy {
                workingDirectory = copy.path
                invocation = try confined(invocation, copy: copy, runDirectory: runDirectory, harness: seat.harness)
            }
            // A shell reports $PWD as inherited when it names the working directory, so it must match the path we gave.
            // PATH comes from the harness, not the sandbox wrapper argv[0] may now be.
            let seatPath = ProcessRunner.path(for: executable, base: environment["PATH"] ?? "/usr/bin:/bin")
            var launchRequest: [String: Any] = ["argv": invocation.argv, "cwd": workingDirectory,
                                                "env": invocation.environment.merging(["PWD": workingDirectory, "PATH": seatPath]) { _, mine in mine },
                                                "reservation": ["seconds": seat.capSeconds]]
            if invocation.stdoutIsAnswer { launchRequest["stdout"] = answerFile }
            else if invocation.usage == .codexEvents { launchRequest["stdout"] = UsageFormat.eventsFile(besides: answerFile) }
            // The token reaches the seat's environment but never the ledger, which keeps launch environments in clear.
            let capability = ThreadStore.newCapability()
            launchRequest["secret_env"] = ["AGENCIL_CAP": capability]
            let began = Date()
            let started: [String: Any]
            // The exchange is tied to its launch before the seat can start, so a crash never orphans a running group.
            var attached: String?
            do {
                started = try launch(launchRequest, onIntent: { id in
                    // The parent's authority ends with its exchange: admission is rechecked at the last moment.
                    if let parent, (try self.threads.capability(launch: parent.launchID))?.live != true {
                        throw Failure(message: "refused: capability expired")
                    }
                    try self.threads.attach(launch: id, thread: thread.id, seq: exchange.seq)
                    try self.threads.issueCapability(capability, launch: id, thread: thread.id, seq: exchange.seq)
                    attached = id
                })
            } catch {
                if let id = attached { failWhenClosed(thread: thread.id, seq: exchange.seq, launch: id, reason: "the seat could not be started: \(error.localizedDescription)") }
                else { finishExchange(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil, reason: "the seat could not be started") }
                return reply(thread, awaiting: exchange.seq, wait: 0)
            }
            guard let launchID = started["run"] as? String else { return fail("the seat could not be started") }
            // A stop that arrived before the launch was attached found nothing to end; end it now.
            if tracking.withLock({ stoppedThreads.contains(key) }), let run = tracking.withLock({ tracked[launchID] }) { terminate(run) }
            Thread.detachNewThread { [self] in complete(thread: thread, seq: exchange.seq, launchID: launchID, answerFile: answerFile, seat: seat, began: began, usage: invocation.usage) }
            return reply(thread, awaiting: exchange.seq, wait: wait)
        } catch {
            // Setup failed before any seat ran: the exchange must not stay asking and block every follow-up.
            finishExchange(thread: thread.id, seq: exchange.seq, state: .failed, answer: nil,
                                reason: "the seat could not be set up: \(error.localizedDescription)")
            throw error
        }
    }

    /// Waits for the seat's leader to exit, ends whatever it left in the group, and records what it answered.
    private func complete(thread: ThreadRecord, seq: Int, launchID: String, answerFile: String, seat: Seat, began: Date, usage format: UsageFormat?) {
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
            finishExchange(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "stopped")
        } else if ranFor >= Double(seat.capSeconds) {
            finishExchange(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "\(seat.harness) ran past its \(seat.capSeconds) second cap")
        } else if status == 0 {
            // The JSON stream, when the harness wrote one, carries the answer too; if it cannot be read the file is the answer as before.
            let captured = format.map { UsageCapture.read($0, answerFile: answerFile) }
            let written = (try? String(contentsOfFile: answerFile, encoding: .utf8)) ?? ""
            let text = (captured?.answer ?? written).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                finishExchange(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "\(seat.harness) answered nothing")
            } else {
                if let usage = captured?.usage { recordUsage(usage, thread: thread.id, seq: seq, seat: seat) }
                finishExchange(thread: thread.id, seq: seq, state: .answered, answer: text, reason: nil)
            }
        } else {
            let stated = format.flatMap { UsageCapture.failure($0, answerFile: answerFile) }.map { String($0.prefix(200)) }
            let detail = (stated ?? lastLine(ofLog: launchID)).map { ": \($0)" } ?? ""
            let code = status.map { "status \($0)" } ?? "an unknown status"
            finishExchange(thread: thread.id, seq: seq, state: .failed, answer: nil, reason: "\(seat.harness) exited with \(code)\(detail)")
        }
    }

    func lastLine(ofLog launchID: String) -> String? {
        let log = directory.appendingPathComponent("runs/\(launchID).log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map { String($0.prefix(200)) }
    }

    // MARK: replies

    func reply(_ thread: ThreadRecord, awaiting seq: Int, wait: Int) -> [String: Any] {
        let deadline = Date().addingTimeInterval(Double(wait))
        var exchange = (try? threads.exchanges(thread: thread.id))?.first { $0.seq == seq }
        while exchange?.state == .asking, Date() < deadline {
            usleep(20_000)
            exchange = (try? threads.exchanges(thread: thread.id))?.first { $0.seq == seq }
        }
        var data: [String: Any] = ["thread": thread.id, "seat": thread.seat, "chain": exchange?.chain ?? [], "substituted": thread.substituted ?? NSNull(),
                                   "state": Self.stateName(exchange?.state ?? .asking)]
        data.merge(costFields(thread: thread.id, seq: seq)) { _, mine in mine }
        if let answer = exchange?.answer { data["answer"] = answer }
        if let reason = exchange?.reason { data["reason"] = reason }
        return ["ok": true, "data": data]
    }

    static func stateName(_ state: Exchange.State) -> String {
        state == .asking ? "pending" : state.rawValue
    }

    func waitSeconds(_ request: [String: Any], fallback: Int = defaultWait) -> Int {
        min(max(request["wait_seconds"] as? Int ?? fallback, 0), 3600)
    }
}

extension Broker {
    /// Exchanges that were asking when a broker died: each fails once its launch is proven closed, never before,
    /// so a follow-up cannot start while the old process group is still alive. An exchange with no recorded launch
    /// waits for every launch that was open at startup.
    func reconcileExchanges() {
        // A copy left by a broker that died between ending an exchange and removing it. An unreadable ledger removes nothing.
        let unfinished = try? threads.unfinished()
        if let unfinished { removeStrandedCopies(except: Set(unfinished.map { "\($0.thread)-\($0.seq)" })) }
        guard let open = unfinished, !open.isEmpty else { return }
        let startup = Set(((try? store.open()) ?? []).map(\.id))
        Thread.detachNewThread { [self] in
            for item in open {
                let waitFor = item.launchID.map { [$0] } ?? Array(startup)
                waitUntilClosed(waitFor)
                finishExchange(thread: item.thread, seq: item.seq, state: .failed, answer: nil,
                                    reason: "the broker restarted before the seat answered", runStatus: "interrupted")
            }
        }
    }

    /// Fails the exchange only after the launch's group is proven empty.
    func failWhenClosed(thread: String, seq: Int, launch: String, reason: String) {
        Thread.detachNewThread { [self] in
            waitUntilClosed([launch])
            finishExchange(thread: thread, seq: seq, state: .failed, answer: nil, reason: reason)
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
