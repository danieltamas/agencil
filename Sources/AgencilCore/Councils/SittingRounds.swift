import Foundation

/// How one run of a seat in a sitting ended.
enum Outcome {
    case unplaceable(String, refused: Bool)
    case answer(String)
    case failed(String)
    case silent, stopped, deadline
}

/// Seat runs of a sitting: each goes through the same admission, budget, capacity, residency, policy and confinement
/// as an ask, then is watched for silence, the sitting's deadline and a stop.
extension Broker {
    private func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    func sitRun(_ s: SittingRun, seat: Seat, prompt: String) -> Outcome {
        if s.isOver { return .stopped }
        // Like an ask, a seat already in the chain is refused at any hop limit.
        if s.chain.contains(seat.name) {
            return .unplaceable("refused: cycle " + (s.chain + [seat.name]).joined(separator: " -> "), refused: true)
        }
        let executable: String?
        switch Resolver.usable(seat, resolverWorld()) {
        case .success(let path): executable = path
        case .failure(let problem): return .unplaceable(problem.reason, refused: false)
        }
        let repo = s.snapshot.repo
        if repo != nil, seat.harness == "ollama" { return .unplaceable("ollama seats cannot read a repo", refused: false) }
        var held: Admitted?
        let thread: String
        do {
            if let refusal = Placement.refusal(seat: seat, route: s.route, hasRepo: repo != nil) { throw refusal }
            if repo != nil { _ = try Confinement.executable(environment: environment) }
            let admitted = try admit(seat, requested: s.council.name, caller: s.caller, parent: s.parent, prompt: prompt, config: s.config)
            held = admitted
            // Waiting for a place may have outlasted a stop or the deadline; nothing is launched after either.
            if s.isOver { abandon(admitted); return .stopped }
            let resolved = Resolved(seat: seat, route: s.route, substituted: nil, executable: executable, admitted: admitted)
            let reply = try run(resolved, caller: s.caller, chain: s.chain + [seat.name], parent: s.parent, requested: s.council.name,
                                question: prompt, files: [], repo: repo, thread: nil, limits: s.config.limits, wait: 0,
                                placeWait: max(1, Int(s.deadline.timeIntervalSinceNow)), snapshot: s.snapshot, verbatim: true, isOver: { s.isOver })
            guard let id = (reply["data"] as? [String: Any])?["thread"] as? String else {
                return .failed("the seat could not be started")
            }
            thread = id
        } catch let refusal as Refusal {
            if let held { abandon(held) }
            return .unplaceable(refusal.message, refused: refusal.exit == 3)
        } catch {
            if let held { abandon(held) }
            return .unplaceable(error.localizedDescription, refused: false)
        }
        s.track(thread, running: true)
        defer { s.track(thread, running: false) }
        return watch(s, seat: seat, thread: thread)
    }

    /// Polls the exchange until it ends. A seat that stops growing its log and answer file for a share of its cap is
    /// ended, and so is everything still running when the sitting is stopped or runs out of time.
    private func watch(_ s: SittingRun, seat: Seat, thread: String) -> Outcome {
        let limit = s.council.silentAfter * Double(seat.capSeconds)
        let answer = directory.appendingPathComponent("runs/\(thread)-1/answer.txt").path
        var ending: Outcome?
        var seen = -1
        var lastChange = Date()
        var unreadable = 0
        while true {
            guard let exchange = (try? threads.exchanges(thread: thread))?.first else {
                // A ledger that cannot be read must not outlast a stop or the deadline.
                unreadable += 1
                if unreadable > 50, s.isOver { _ = try? stopThread(thread); return .failed("the ledger could not be read") }
                usleep(20_000); continue
            }
            unreadable = 0
            switch exchange.state {
            case .answered: return .answer(exchange.answer ?? "")
            case .failed: return ending ?? .failed(exchange.reason ?? "the seat failed")
            case .asking: break
            }
            if ending == nil {
                if s.locked({ s.stopped }) { ending = .stopped } else if Date() >= s.deadline { ending = .deadline }
                else if let launch = exchange.launchID, seat.harness != "ollama" {
                    let grown = size(directory.appendingPathComponent("runs/\(launch).log").path) + size(answer)
                    if grown != seen { seen = grown; lastChange = Date() }
                    else if Date().timeIntervalSince(lastChange) > limit { ending = .silent }
                }
                if ending != nil { _ = try? stopThread(thread) }
            }
            usleep(20_000)
        }
    }

    // MARK: one seat in one round

    /// Runs `slot`'s seat for `round`, retrying an answer that does not validate once. In the blind round a seat that
    /// cannot run, or goes silent, is replaced by a spare; later rounds leave its earlier answer standing.
    func sitPlay(_ s: SittingRun, slot: Slot, round: String, prompt: (Seat) -> String) {
        let replaceable = round == "blind"
        s.locked { slot.phase = .running; slot.round = round; slot.result = nil }
        var seat = s.locked { slot.seat }
        var started = Date()
        var retried = false
        var text = prompt(seat)

        func settle(_ phase: Slot.Phase, _ reason: String) {
            // A seat that fails a later round keeps the answer it gave before.
            s.locked { if replaceable { slot.phase = phase; slot.reason = reason } else { slot.phase = .answered } }
        }
        func swap() -> Bool {
            guard replaceable, let next = s.takeSpare() else { return false }
            seat = next; started = Date(); retried = false; text = prompt(next)
            s.locked { slot.seat = next }
            return true
        }
        while true {
            let began = Date()
            let outcome = sitRun(s, seat: seat, prompt: text)
            // An attempt without a usable answer still ran, so the ledger keeps it as exit 1; a usable one is stored with
            // its round as exit 0. A seat that could not be placed never ran: availability is not a run (docs/U25-SPEC.md).
            if case .answer(let answer) = outcome, case .success = AnswerContract.parse(answer, requireVote: round != "challenge") {
            } else if case .unplaceable = outcome {
            } else {
                _ = try? sittingRows.seatRun(sitting: s.id, seat: seat, started: began, ended: Date(), exit: 1)
            }
            switch outcome {
            case .answer(let answer):
                switch AnswerContract.parse(answer, requireVote: round != "challenge") {
                case .success(let parsed):
                    s.locked {
                        slot.phase = .answered; slot.reason = nil; slot.vote = parsed.vote ?? slot.vote
                        slot.result = RoundResult(seat: seat, started: started, answer: parsed)
                    }
                    return
                case .failure(let problem):
                    if retried {
                        s.locked { slot.phase = .failed; slot.reason = "failed: unparsable"; slot.excluded = true; slot.vote = nil }
                        return
                    }
                    retried = true
                    text = SittingPrompt.retry(prompt(seat), error: problem.message)
                }
            case .unplaceable(let reason, let refused):
                if swap() { continue }
                settle(refused ? .refused : .failed, reason)
                return
            case .silent:
                if swap() { continue }
                settle(.abstained, "silent")
                return
            case .failed(let reason):
                settle(.failed, reason)
                return
            case .stopped: settle(.abstained, "stopped"); return
            case .deadline: settle(.abstained, "deadline"); return
            }
        }
    }

    /// Runs one round over `slots`, all at once subject to capacity, then stores what they said.
    func sitRound(_ s: SittingRun, _ round: String, slots: [Slot], prompt: @escaping (Slot, Seat) -> String) throws {
        s.setRound(round)
        try sittingRows.setRound(s.id, round)
        let group = DispatchGroup()
        for slot in slots {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                sitPlay(s, slot: slot, round: round) { prompt(slot, $0) }
            }
        }
        group.wait()
        try sitStore(s, round: round)
    }

    /// Claims get their global ids in seat order, and every assessment of a known claim by another seat is kept.
    private func sitStore(_ s: SittingRun, round: String) throws {
        var runs: [(slot: Slot, id: String)] = []
        for slot in s.slots {
            guard let result = s.locked({ slot.result }) else { continue }
            let id = try sittingRows.seatRun(sitting: s.id, seat: result.seat, started: result.started, ended: result.ended, exit: 0)
            runs.append((slot, id))
            guard round != "challenge" else { continue }
            for claim in result.answer?.claims ?? [] {
                let stored = StoredClaim(id: "AG-\(s.number)-\(s.claims.count + 1)", seat: result.seat.name, vendor: result.seat.vendor, claim: claim)
                try sittingRows.claim(stored, sitting: s.id, seatRun: id)
                s.append(stored)
            }
        }
        for (slot, runID) in runs {
            guard let result = s.locked({ slot.result }) else { continue }
            s.forgetStances(of: result.seat.name)
            for item in result.answer?.assessments ?? [] {
                guard s.claims.contains(where: { $0.id == item.claim && $0.seat != result.seat.name }) else { continue }
                try sittingRows.assessment(claim: item.claim, stance: item.stance, why: item.why, sitting: s.id,
                                           snapshot: s.snapshot.id, seatRun: runID)
                s.record(stance: item.stance, why: item.why ?? "", claim: item.claim, seat: result.seat.name)
            }
        }
    }
}
