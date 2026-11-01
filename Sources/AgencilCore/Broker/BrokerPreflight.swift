import Foundation

/// Preflight (docs/U25-SPEC.md): a seat's availability is settled before any work, kept in the ledger, and read by
/// every resolution. A seat is probed only when it has no fresh standing; a probe is one bounded harness process.
extension Broker {
    static let probePrompt = "Reply with exactly: OK"
    private static let probeCap = 60
    private static let modelsCap: Duration = .seconds(30)
    private static let probeGrace: Duration = .seconds(1)

    /// The resolver's world with the seat's fresh standing: a seat known to be down is unusable without a new process.
    func resolverWorld() -> ResolverWorld {
        discovery.world(environment: environment, home: directory) { [preflights] seat in
            guard let standing = try? preflights.fresh(seat), standing.reason != .ok else { return nil }
            return standing.failure
        }
    }

    // MARK: the op

    func preflightOp(_ request: [String: Any], peer: Int32?, peerStart: Double?) throws -> [String: Any] {
        let (config, _) = try seatConfig()
        var seats = config.seats
        if let names = request["seats"] {
            guard let names = names as? [String] else { throw Failure(message: "seats must be a list of seat names", exit: 64) }
            seats = try names.map { name in
                guard let seat = config.seat(named: name) else { throw Failure(message: "unknown seat \(name)", exit: 64) }
                return seat
            }
        }
        let probing = request["probe"] as? Bool == true
        if probing { try requireOwner(request, peer: peer, peerStart: peerStart) }
        let probed = probing ? Self.byName(standings(of: seats, limits: config.limits, parent: nil, force: true)) : [:]
        let rows = try seats.map { seat -> [String: Any] in
            let standing = probing ? probed[seat.name] : try preflights.fresh(seat)
            var row: [String: Any] = ["name": seat.name, "harness": seat.harness, "model": seat.model, "plan": seat.plan.rawValue,
                                      "reason": standing?.reason.rawValue ?? "not probed", "detail": standing?.detail ?? ""]
            if let standing {
                row["probed_ago"] = Date().timeIntervalSince(standing.probedAt)
                if let until = standing.until { row["until"] = until }
            }
            let rate = try preflights.availability(seat: seat.name)
            row["availability"] = ["ok": rate.ok, "probes": rate.probes]
            return row
        }
        return reply(["seats": rows])
    }

    // MARK: the wake gate

    /// Every seated slot and every non-recused synthesizer must stand `ok` before the sitting opens. A seat that a
    /// hard budget refuses is never probed and fails with the budget's words. A failed slot takes the first `ok`
    /// spare whose vendor is not seated already; anything left failing refuses the wake with every failed seat named.
    /// Returns whether a spare sat down.
    func preflightGate(slots: [Slot], spares: inout [Seat], council: Council, config: SeatConfig, author: String,
                       caller: String, parent: CapabilityRun?, question: String) throws -> Bool {
        let seated = slots.filter { $0.phase == .pending }
        let synthesizers = council.synthesizers.compactMap { config.seat(named: $0) }.filter { author == "unknown" || $0.vendor != author }
        if !council.synthesizers.isEmpty, synthesizers.isEmpty {
            throw Refusal(exit: 4, message: "failed: preflight: every synthesizer is of the author's vendor")
        }
        // The budget is checked the way admission will check it, without a reservation: the question stands in for
        // the blind prompt, so an unbounded seat under a hard budget is refused here, before any probe process.
        let rootKey = try parent.flatMap { try budgets.reservation(thread: $0.thread, seq: $0.seq)?.rootKey } ?? caller
        func budgetRefusal(_ seat: Seat) throws -> String? {
            let matching = BudgetStore.matching(config.budgets, route: council.name, root: rootKey, vendor: seat.harness)
            return try budgets.admit(id: "", quote: Self.quote(seat, prompt: question), budgets: matching, routeKey: council.name,
                                     rootKey: rootKey, vendor: seat.harness, commit: false, free: seat.plan == .free)?.message
        }
        var refused: [String: String] = [:]
        var probing: [Seat] = []
        for seat in seated.map(\.seat) + synthesizers {
            if let message = try budgetRefusal(seat) { refused[seat.name] = message } else { probing.append(seat) }
        }
        let standings = Self.byName(self.standings(of: probing, limits: config.limits, parent: parent, force: false))
        func isOK(_ seat: Seat) -> Bool { refused[seat.name] == nil && standings[seat.name]?.reason == .ok }
        func failure(_ seat: Seat) -> String? {
            refused[seat.name].map { "\(seat.name) \($0)" } ?? standings[seat.name].map { "\($0.seat) \($0.summary)" }
        }
        var failures: [String] = []
        var fallbackUsed = false
        for slot in seated where !isOK(slot.seat) {
            var replaced = false
            var index = 0
            while index < spares.count {
                let candidate = spares[index]
                guard !seated.contains(where: { $0 !== slot && $0.seat.vendor == candidate.vendor }) else { index += 1; continue }
                // A spare that is not ok is spent either way; one of a seated vendor may still serve another slot.
                spares.remove(at: index)
                if try budgetRefusal(candidate) == nil,
                   self.standings(of: [candidate], limits: config.limits, parent: parent, force: false).first?.reason == .ok {
                    slot.seat = candidate; fallbackUsed = true; replaced = true
                    break
                }
            }
            if !replaced, let line = failure(slot.seat) { failures.append(line) }
        }
        if !synthesizers.isEmpty, !synthesizers.contains(where: isOK) {
            for seat in synthesizers { if let line = failure(seat) { failures.append(line) } }
        }
        guard failures.isEmpty else { throw Refusal(exit: 4, message: "failed: preflight: " + failures.joined(separator: "; ")) }
        return fallbackUsed
    }

    // MARK: probing

    /// The standing of every seat, probing those without a fresh one (`force` probes all). Seats are probed side by
    /// side within the broker's places (`seats_at_once`, the process cap); opencode seats also take turns at the gate.
    /// `parent` is the seat whose wake this is: it yields its place to the probes as it would to its children.
    func standings(of seats: [Seat], limits: Limits, parent: CapabilityRun?, force: Bool) -> [PreflightStanding] {
        let box = StandingBox()
        var pending: [Seat] = []
        for seat in seats {
            if !force, let fresh = try? preflights.fresh(seat) { box.set(fresh) } else { pending.append(seat) }
        }
        // One discovery pass for every probe of this batch, instead of one per seat thread.
        if pending.contains(where: { $0.harness != "ollama" }) { _ = discovery.snapshot(environment: environment, home: directory, force: false) }
        let group = DispatchGroup()
        for seat in pending {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                box.set(placed(seat, limits: limits, parentExchange: parent.map { "\($0.thread)-\($0.seq)" }) { probe(seat) })
            }
        }
        group.wait()
        return seats.compactMap { box.get($0.name) }
    }

    /// Runs a probe holding a place like a seat run does (process cap, memory floor, `seats_at_once`). A probe that
    /// gets no place within the seat's cap is `busy`, and that standing is not recorded: a full broker says nothing
    /// about the seat itself.
    private func placed(_ seat: Seat, limits: Limits, parentExchange: String?, _ run: () -> PreflightStanding) -> PreflightStanding {
        func busy(_ detail: String) -> PreflightStanding { standing(seat, .busy, detail) }
        let id = "pf_" + UUID().uuidString.lowercased()
        guard let orphans = try? orphanCount() else { return busy("the ledger could not be read") }
        guard capacity.enter(id, parentExchange: parentExchange, isProcess: seat.harness != "ollama", limits: limits, orphans: orphans) else {
            return busy("the process cap is reached")
        }
        defer { capacity.leave(id) }
        // Like admission: a floor that cannot be measured is a floor not met.
        if limits.memoryFloorMB > 0, freeMemoryMB().map({ $0 < limits.memoryFloorMB }) != false { return busy("below the memory floor") }
        let deadline = Date().addingTimeInterval(Double(cap(seat)))
        while true {
            guard let orphans = try? orphanCount() else { return busy("the ledger could not be read") }
            if capacity.activate(id, limits: limits, orphans: orphans) { return run() }
            if Date() >= deadline { return busy("no seat place within \(cap(seat)) seconds") }
            usleep(20_000)
        }
    }

    /// One probe of one seat, recorded whatever it finds.
    func probe(_ seat: Seat) -> PreflightStanding {
        let (reason, detail, until) = measure(seat)
        let result = standing(seat, reason, detail, until: until)
        try? preflights.record(result)
        return result
    }

    private func standing(_ seat: Seat, _ reason: PreflightReason, _ detail: String, until: String? = nil) -> PreflightStanding {
        PreflightStanding(seat: seat.name, harness: seat.harness, model: seat.model, plan: seat.plan.rawValue,
                          reason: reason, detail: detail, until: until, probedAt: Date())
    }

    private func measure(_ seat: Seat) -> (PreflightReason, String, String?) {
        let executable: String
        switch Resolver.installed(seat, discovery.world(environment: environment, home: directory)) {
        case .failure(let problem): return (PreflightReason.unusable(problem.reason), PreflightClassifier.clean(problem.reason), nil)
        // An ollama seat whose endpoint answers and lists the model is ready: no chat request is made.
        case .success(.none): return (.ok, "", nil)
        case .success(.some(let path)): executable = path
        }
        guard seat.harness == "opencode" else { return answer(seat, executable: executable) }
        guard opencodeGate.wait(timeout: .now() + Double(cap(seat))) == .success else { return (.busy, "another opencode run holds the gate", nil) }
        defer { opencodeGate.signal() }
        if case .success(let output) = runProcess([executable, "models"], directory: nil, environment: [:], timeout: Self.modelsCap),
           output.status == 0 {
            let listed = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            if !listed.contains(seat.model) { return (.modelUnavailable, "not in opencode models", nil) }
        }
        return answer(seat, executable: executable)
    }

    private func cap(_ seat: Seat) -> Int { min(seat.capSeconds, Self.probeCap) }

    /// The one-line probe through the seat's own adapter, inside a run directory of its own: two probes of one seat
    /// at once (a wake and a `preflight --probe`) never share an answer file. The directory goes when the probe ends.
    private func answer(_ seat: Seat, executable: String) -> (PreflightReason, String, String?) {
        let runDirectory = directory.appendingPathComponent("runs/preflight/\(seat.name)/\(UUID().uuidString.lowercased())")
        let answerFile = runDirectory.appendingPathComponent("answer.txt")
        defer { try? FileManager.default.removeItem(at: runDirectory) }
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let invocation = try Adapter.command(seat: seat, executable: executable, prompt: Self.probePrompt,
                                                       answerFile: answerFile.path, runDirectory: runDirectory.path) else {
                return (.error, "\(seat.harness) has no adapter", nil)
            }
            let cwd = invocation.workingDirectory ?? runDirectory.path
            let result = runProcess(invocation.argv, directory: URL(fileURLWithPath: cwd),
                                    environment: invocation.environment.merging(["PWD": cwd]) { _, mine in mine }, timeout: .seconds(cap(seat)))
            switch result {
            case .failure(.timedOut): return (.timeout, "no answer within \(cap(seat)) seconds", nil)
            case .failure(let failure): return (.error, PreflightClassifier.clean(String(describing: failure)), nil)
            case .success(let output):
                let stdout = String(decoding: output.stdout, as: UTF8.self)
                let said = invocation.stdoutIsAnswer ? stdout : (try? String(contentsOf: answerFile, encoding: .utf8)) ?? ""
                let text = stdout + "\n" + output.stderr
                let (reason, detail) = PreflightClassifier.classify(status: output.status, output: text,
                                                                    answer: said.trimmingCharacters(in: .whitespacesAndNewlines))
                return (reason, detail, reason == .usageLimit ? PreflightClassifier.until(in: text) : nil)
            }
        } catch {
            return (.error, PreflightClassifier.clean(error.localizedDescription), nil)
        }
    }

    private func runProcess(_ argv: [String], directory: URL?, environment: [String: String],
                            timeout: Duration) -> Result<ProcessOutput, ProcessRunner.Failure> {
        let finished = DispatchSemaphore(value: 0)
        let box = ProcessResultBox()
        Task.detached { @Sendable in
            do { box.value = .success(try await ProcessRunner().run(argv, in: directory, environment: environment, timeout: timeout, gracePeriod: Self.probeGrace)) }
            catch let failure as ProcessRunner.Failure { box.value = .failure(failure) }
            catch { box.value = .failure(.spawnFailed(String(describing: error))) }
            finished.signal()
        }
        finished.wait()
        return box.value ?? .failure(.spawnFailed("the probe produced no result"))
    }

    private static func byName(_ standings: [PreflightStanding]) -> [String: PreflightStanding] {
        Dictionary(standings.map { ($0.seat, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: the opencode gate

    /// Takes the opencode gate for an exchange, waiting up to `wait` seconds; false when another run still holds it.
    func holdOpencode(exchange key: String, wait: Int) -> Bool {
        guard opencodeGate.wait(timeout: .now() + Double(max(wait, 1))) == .success else { return false }
        tracking.withLock { _ = opencodeHeld.insert(key) }
        return true
    }

    func releaseOpencode(exchange key: String) {
        if tracking.withLock({ opencodeHeld.remove(key) != nil }) { opencodeGate.signal() }
    }
}

private final class StandingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var standings: [String: PreflightStanding] = [:]
    func set(_ standing: PreflightStanding) { lock.withLock { standings[standing.seat] = standing } }
    func get(_ seat: String) -> PreflightStanding? { lock.withLock { standings[seat] } }
}

private final class ProcessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ProcessOutput, ProcessRunner.Failure>?
    var value: Result<ProcessOutput, ProcessRunner.Failure>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
