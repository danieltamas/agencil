import Foundation

/// `wake`, `result`, `status` and `stop` for sittings: a council convened on one question, from open to verdict.
extension Broker {
    private static let builtinVendors: Set<String> = ["anthropic", "openai", "google", "meta", "mistral", "alibaba", "deepseek",
                                                      "moonshot", "zhipu", "xai"]
    static let defaultSittingWait = 60

    /// A `commit` is a full lowercase sha that names a commit of the repo; it pins the snapshot instead of `HEAD`.
    private func pinnedCommit(_ value: Any?, repo: String?) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let sha = value as? String, sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil, let repo,
              RepoCopy.output(["-C", repo, "rev-parse", "--verify", sha + "^{commit}"]) == sha else {
            throw Refusal(exit: 64, message: "usage: commit must be the full sha of a commit in the repo")
        }
        return sha
    }

    func wake(_ request: [String: Any], peer: Int32?, peerStart: Double?) -> [String: Any] {
        let socketCaller = request["caller"] as? String ?? "unknown"
        let origin: Origin
        switch attribute(peer: peer, peerStart: peerStart, capability: request["cap"] as? String) {
        case .failure(let refusal):
            try? threads.recordRequest(caller: socketCaller, outcome: "refused")
            return Self.failure(refusal.message, exit: refusal.exit)
        case .success(let found): origin = found
        }
        let parent: CapabilityRun?
        if case .child(let run) = origin { parent = run } else { parent = nil }
        let caller = parent?.seat ?? (socketCaller == "owner" ? (request["as"] as? String ?? "owner") : socketCaller)
        guard let name = request["council"] as? String, let kind = request["change_kind"] as? String, !kind.isEmpty,
              let question = (request["question"] ?? request["brief"]) as? String, !question.isEmpty else {
            return Self.failure("wake needs a council, a change_kind and a question", exit: 64)
        }
        func settle(_ refusal: Refusal, _ outcome: String = "refused") -> [String: Any] {
            try? threads.recordRequest(caller: caller, outcome: outcome)
            return Self.failure(refusal.message, exit: refusal.exit)
        }
        let config: SeatConfig
        do { config = try SeatConfig(values: try ConfigStore(directory: directory).read().values) } catch let problem as ConfigProblem {
            return settle(Refusal(exit: 4, message: problem.message), "failed")
        } catch {
            return Self.failure(error.localizedDescription, exit: 70)
        }
        let kinds = parent.flatMap { config.seat(named: $0.seat)?.harness }.map { [$0] } ?? []
        // The owner's own panel needs no route: routes limit agents. The wire's `caller` is only a claim, so the
        // exemption also needs the connection to come from the app's own process (docs/U27-SPEC.md item 1).
        let ownerRoute = caller == "owner" && parent == nil && request["as"] == nil && isAppPeer(peer)
            ? Route(callers: ["owner"], target: name, hopLimit: 1, fallbacks: []) : nil
        guard let route = config.route(from: [caller] + kinds, to: name) ?? ownerRoute else {
            return settle(Refusal(exit: 3, message: "refused: no route from \(caller) to \(name)"))
        }
        guard let council = config.council(named: name) else { return settle(Refusal(exit: 4, message: "failed: no council named \(name)")) }
        if (parent?.chain.count ?? 0) > route.hopLimit { return settle(Refusal(exit: 3, message: "refused: hop limit")) }
        do {
            let policy = parent != nil || socketCaller != "owner" ? try attachPolicy(request, peer: peer) : nil
            let repo = try repository(request["repo"])
            let attached = try AttachedFiles.readAll(request["files"], atMost: 8, policy: policy)
            let synthesize = try Self.synthesizeFlag(request["synthesize"])
            let author = authorVendor(request["author_vendor"] as? String, parent: parent, config: config)
            let chosen = try Self.chosenSeats(request["seats"], council: council)
            let cap = try Self.capOverride(request["cap_seconds"])
            func shortened(_ seat: Seat) -> Seat { cap.map { seat.capped(at: $0) } ?? seat }
            let slots = chosen.compactMap { config.seat(named: $0) }.map(shortened).map { seat -> Slot in
                let slot = Slot(seat: seat)
                if author != "unknown", seat.vendor == author { slot.phase = .recused; slot.reason = "same vendor as the author" }
                return slot
            }
            var spares = council.spares.compactMap { config.seat(named: $0) }.map(shortened).filter { author == "unknown" || $0.vendor != author }
            // A malformed request is refused before any seat is probed; then the panel is checked before anything is
            // written, so a council that cannot sit leaves no run behind.
            let councilRoute = Route(callers: route.callers, target: route.target, hopLimit: route.hopLimit, fallbacks: [],
                                     localOnly: route.localOnly || council.localOnly, requires: route.requires)
            let commit = try pinnedCommit(request["commit"], repo: repo)
            let fallbackUsed: Bool
            do {
                fallbackUsed = try preflightGate(slots: slots, spares: &spares, council: council, config: config, author: author,
                                                 caller: caller, parent: parent, question: question, route: councilRoute)
            }
            catch let refusal as Refusal { return settle(refusal, "failed") }
            let snapshot = try Snapshot.take(repo: repo, uncommitted: request["uncommitted"] as? Bool ?? false, question: question, commit: commit)
            let seatsLine = (request["seats"] as? [String]).map { "seats: \($0.joined(separator: ","))" }
            let capLine = cap.map { "cap: \($0)" }
            let brief = ["change_kind: \(kind)", "question: \(question)", request["diff"].flatMap { $0 as? String }.map { "diff: \($0)" },
                         "author_vendor: \(author)",
                         seatsLine, capLine].compactMap { $0 }.joined(separator: "\n") + "\n"
                + attached.paths.map { "file: \($0)\n" }.joined() + Self.imagesNotShown(attached.images, council: council, config: config)
            let opened = try sittingRows.open(council: council.name, snapshot: snapshot, authorVendor: author, brief: brief,
                                              project: ProjectLabel.clean(request["project"]), caller: caller)
            let sitting = SittingRun(id: opened.id, number: opened.number, council: council, config: config, route: councilRoute,
                                     caller: caller, parent: parent, snapshot: snapshot, changeKind: kind,
                                     diffRange: request["diff"] as? String, question: question, authorVendor: author, slots: slots,
                                     spares: spares, attached: attached.files, images: attached.images)
            sitting.wantsSummary = synthesize
            if fallbackUsed { sitting.noteFallback() }
            tracking.withLock { sittings[opened.id] = sitting }
            try? threads.recordRequest(caller: caller, outcome: "accepted", runID: opened.id)
            Thread.detachNewThread { [self] in conduct(sitting) }
            return sittingReply(opened.id, wait: waitSeconds(request, fallback: Self.defaultSittingWait))
        } catch let refusal as Refusal {
            return settle(refusal)
        } catch let failure as Failure {
            return Self.failure(failure.message, exit: failure.exit)
        } catch {
            return Self.failure(error.localizedDescription, exit: 70)
        }
    }

    /// The brief line naming the council's seats that will not see the attached images; empty when every seat can.
    private static func imagesNotShown(_ images: [AttachedImage], council: Council, config: SeatConfig) -> String {
        guard !images.isEmpty else { return "" }
        let blind = (council.seats + council.spares + council.synthesizers).compactMap { config.seat(named: $0) }
            .filter { !Adapter.seesImages($0.harness) }.map(\.name)
        return blind.isEmpty ? "" : "images_not_shown: \(blind.joined(separator: ", "))\n"
    }

    /// The panel runs in the broker's own process, so its connection's peer is this process. With test seams on, a
    /// named peer stands in for it.
    func isAppPeer(_ peer: Int32?) -> Bool {
        guard let peer else { return false }
        if peer == getpid() { return true }
        return environment["AGENCIL_TEST_SEAMS"] == "1" && environment["AGENCIL_TEST_APP_PEER"].flatMap(Int32.init) == peer
    }

    /// The brief's author vendor when it names a vendor the sitting can reason about, else the vendor of the seat that
    /// made the call, else `unknown`: recusal that cannot be proven is flagged, never guessed.
    private func authorVendor(_ stated: String?, parent: CapabilityRun?, config: SeatConfig) -> String {
        let known = Self.builtinVendors.union(config.seats.map(\.vendor))
        if let stated = stated?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !stated.isEmpty {
            return known.contains(stated) ? stated : "unknown"
        }
        return parent.flatMap { config.seat(named: $0.seat)?.vendor } ?? "unknown"
    }

    // MARK: conducting

    private func header(_ s: SittingRun, _ round: String, _ seat: Seat) -> String {
        SittingPrompt.header(round: round, sitting: s.id, seat: seat.name, snapshot: s.snapshot.id, kind: s.changeKind,
                             diff: s.diffRange, question: s.question, attached: s.attached)
    }

    private func conduct(_ s: SittingRun) {
        do {
            let seated = s.slots.filter { $0.phase == .pending }
            try sitRound(s, "blind", slots: seated) { _, seat in SittingPrompt.blind(self.header(s, "blind", seat)) }
            if s.council.rebuttal, !s.isOver {
                let answered = s.slots.filter { $0.phase == .answered && !$0.excluded }
                try sitRound(s, "rebuttal", slots: answered) { _, seat in
                    SittingPrompt.rebuttal(self.header(s, "rebuttal", seat), others: s.standingClaims.filter { $0.seat != seat.name })
                }
            }
            if s.council.challenge, !s.isOver {
                let answered = s.slots.filter { $0.phase == .answered && !$0.excluded }
                let taking = answered.filter { slot in !disputed(s).filter { $0.claim.seat != slot.seat.name }.isEmpty }
                try sitRound(s, "challenge", slots: taking) { _, seat in
                    SittingPrompt.challenge(self.header(s, "challenge", seat), disputed: self.disputed(s).filter { $0.claim.seat != seat.name })
                }
            }
            try sitSynthesis(s)
            try finish(s)
        } catch {
            try? sittingRows.finish(s.id, state: "failed", reason: "the sitting could not be recorded: \(error.localizedDescription)",
                                    json: nil, row: nil)
        }
        tracking.withLock { sittings[s.id] = nil }
    }

    /// p0 and p1 claims that at least one seat disputes, with what every seat said about them.
    private func disputed(_ s: SittingRun) -> [(claim: StoredClaim, stances: [(seat: String, stance: String, why: String)])] {
        let latest = s.locked { s.stances }
        let order = s.slots.map(\.seat.name)
        let out = Set(s.slots.filter(\.excluded).map(\.seat.name))
        return s.standingClaims.compactMap { claim in
            guard ["p0", "p1"].contains(claim.claim.severity) else { return nil }
            let said = (latest[claim.id] ?? [:]).filter { !out.contains($0.key) }
            guard said.values.contains(where: { $0.stance == "dispute" }) else { return nil }
            let rows = said.map { (seat: $0.key, stance: $0.value.stance, why: $0.value.why) }
                .sorted { (order.firstIndex(of: $0.seat) ?? 0) < (order.firstIndex(of: $1.seat) ?? 0) }
            return (claim, rows)
        }
    }

    private func votes(_ s: SittingRun) -> [SeatVote] {
        s.locked {
            s.slots.map { slot in
                let state = SeatVote.State(rawValue: slot.phase.rawValue) ?? .abstained
                return SeatVote(seat: slot.seat.name, vendor: slot.seat.vendor, state: state, vote: slot.excluded ? nil : slot.vote,
                                reason: slot.reason ?? (state == .abstained && !slot.settled ? "deadline" : nil))
            }
        }
    }

    private func input(_ s: SittingRun, synthesizerFailed: Bool?) -> VerdictInput {
        let sat = s.slots.filter { $0.phase != .recused }
        return VerdictInput(council: s.council, convened: sat.count, votes: votes(s), claims: s.standingClaims, assessments: s.assessments(),
                            conveneVendors: s.conveneVendors, fallbackUsed: s.fallbackUsed,
                            authorUnknown: s.authorVendor == "unknown", synthesizerFailed: synthesizerFailed)
    }

    /// The first synthesizer that is not recused and can run summarises the sitting; none left is a failed synthesis, which
    /// the verdict table turns into INCOMPLETE. A council with no synthesizer has its answering seats write the summary in
    /// council order instead: that one is best-effort, and its failure leaves the verdict as computed.
    private func sitSynthesis(_ s: SittingRun) throws {
        let configured = !s.council.synthesizers.isEmpty
        // A fallback writer is the seat in its slot, so a `cap` override of the wake binds its synthesis too.
        let candidates: [Seat] = configured ? s.council.synthesizers.compactMap { s.config.seat(named: $0) }
            : s.wantsSummary ? s.locked { s.slots.filter { $0.phase == .answered && !$0.excluded }.map(\.seat) } : []
        guard configured || !candidates.isEmpty else { return }
        if configured { s.synthesizerFailed = true }
        guard !s.isOver else { return }
        try sittingRows.setRound(s.id, "synthesis")
        s.setRound("synthesis")
        let preview = VerdictTable.decide(input(s, synthesizerFailed: nil))
        let notes = s.locked { s.slots.compactMap { slot in slot.notes.map { (seat: slot.seat.name, text: $0) } } }
        for seat in candidates {
            guard !configured || s.authorVendor == "unknown" || seat.vendor != s.authorVendor else { continue }
            switch writeSummary(s, seat: seat, prompt: SittingPrompt.synthesis(header(s, "synthesis", seat), claims: preview.claims,
                                                                              votes: votes(s), notes: notes)) {
            case .written(let summary):
                s.locked { s.summary = summary; s.summaryBy = seat.name; s.summaryFallback = !configured }
                if configured { s.synthesizerFailed = false }
                return
            case .failed where configured: return
            case .unplaceable, .failed: if s.isOver { return }
            }
        }
    }

    private enum Summary { case written(String), unplaceable, failed }

    /// One seat's run of the synthesis round, retrying an answer that does not validate once.
    private func writeSummary(_ s: SittingRun, seat: Seat, prompt base: String) -> Summary {
        var text = base
        var retried = false
        while true {
            let began = Date()
            let outcome = sitRun(s, seat: seat, round: "synthesis", prompt: text)
            func record(exit: Int) { _ = try? sittingRows.seatRun(sitting: s.id, seat: seat, started: began, ended: Date(), exit: exit) }
            switch outcome {
            case .unplaceable: return .unplaceable
            case .answer(let answer):
                switch AnswerContract.parseSummary(answer) {
                case .success(let summary):
                    record(exit: 0)
                    return .written(summary)
                case .failure(let problem):
                    record(exit: 1)
                    if retried { return .failed }
                    retried = true
                    text = SittingPrompt.retry(base, error: problem.message)
                }
            default:
                record(exit: 1)
                return .failed
            }
        }
    }

    private func finish(_ s: SittingRun) throws {
        if s.locked({ s.stopped }) {
            try sittingRows.finish(s.id, state: "failed", reason: "stopped", json: nil, row: nil)
            return
        }
        let outcome = VerdictTable.decide(input(s, synthesizerFailed: s.synthesizerFailed))
        var json: [String: Any] = [
            "sitting": s.id, "council": s.council.name, "state": "done", "verdict": outcome.verdict, "reasons": outcome.reasons,
            "rule": s.council.rule.rawValue, "high_risk": s.council.highRisk, "snapshot": s.snapshot.id, "author_vendor": s.authorVendor,
            "votes": votes(s).map { vote -> [String: Any] in
                var row: [String: Any] = ["seat": vote.seat, "vendor": vote.vendor, "state": vote.state.rawValue, "valid": vote.valid]
                if let value = vote.vote { row["vote"] = value }
                if let reason = vote.reason { row["reason"] = reason }
                return row
            },
            "claims": outcome.claims.map { standing -> [String: Any] in
                let claim = standing.stored.claim
                var row: [String: Any] = ["id": standing.stored.id, "seat": standing.stored.seat, "vendor": standing.stored.vendor,
                                          "kind": claim.kind, "severity": claim.severity, "confidence": claim.confidence,
                                          "backers": standing.backers, "dissenters": standing.dissenters,
                                          "refuted": standing.refuted, "minority": standing.minority]
                if let file = claim.file { row["file"] = file }
                if let line = claim.line { row["line"] = line }
                if let evidence = claim.evidence { row["evidence"] = evidence }
                if let fix = claim.fix { row["fix"] = fix }
                return row
            },
            "minority": outcome.minority.map { ["claim": $0.claim, "seat": $0.seat, "vendor": $0.vendor] },
            "independence": outcome.flags,
        ]
        if let summary = s.summary {
            json["summary"] = summary
            json["summary_by"] = s.summaryBy
            if s.summaryFallback { json["summary_fallback"] = true }
        }
        let minority = outcome.minority.map { ["claim": $0.claim, "seat": $0.seat, "vendor": $0.vendor] }
        try sittingRows.finish(s.id, state: "done", reason: nil, json: json,
                               row: (outcome.verdict, outcome.flags, minority, s.snapshot.id))
    }

    // MARK: asking about a sitting

    func sittingReply(_ id: String, wait: Int) -> [String: Any] {
        let end = Date().addingTimeInterval(Double(wait))
        var record = try? sittingRows.record(id)
        while record?.state == "running", Date() < end {
            usleep(20_000)
            record = try? sittingRows.record(id)
        }
        guard let record else { return Self.failure("unknown id \(id)", exit: 64) }
        switch record.state {
        case "done": return ["ok": true, "data": record.verdict ?? ["sitting": id, "state": "done"]]
        case "failed":
            return ["ok": true, "data": ["sitting": id, "council": record.council, "state": "failed", "reason": record.reason ?? "failed"]]
        default:
            return ["ok": true, "data": ["sitting": id, "council": record.council, "state": "pending", "round": record.round]]
        }
    }

    func sittingStatus(_ id: String) throws -> [String: Any] {
        guard let record = try sittingRows.record(id) else { throw Failure(message: "unknown id \(id)") }
        let live = tracking.withLock { sittings[id] }
        var seats: [[String: Any]] = []
        if let live {
            seats = live.locked {
                live.slots.map { slot in
                    var row: [String: Any] = ["seat": slot.seat.name, "vendor": slot.seat.vendor, "state": slot.phase.rawValue, "round": slot.round]
                    if let thread = slot.thread { row["thread"] = thread }
                    return row
                }
            }
        } else {
            seats = ((record.verdict?["votes"] as? [[String: Any]]) ?? []).map {
                ["seat": $0["seat"] ?? "", "vendor": $0["vendor"] ?? "", "state": $0["state"] ?? "", "round": record.round]
            }
        }
        return ["ok": true, "data": ["sitting": id, "council": record.council, "state": record.state, "round": record.round, "seats": seats]]
    }

    func stopSitting(_ id: String) throws -> [String: Any] {
        guard try sittingRows.record(id) != nil else { throw Failure(message: "unknown id \(id)") }
        guard let live = tracking.withLock({ sittings[id] }) else { return ["ok": true, "run": id, "stopping": false] }
        live.stop()
        for thread in live.locked({ live.running }) { _ = try? stopThread(thread) }
        return ["ok": true, "run": id, "stopping": true]
    }
}

extension Broker {
    /// The seats of `council` that a `seats` override keeps, in the council's own order; no override keeps them all.
    static func chosenSeats(_ value: Any?, council: Council) throws -> [String] {
        guard let value, !(value is NSNull) else { return council.seats }
        guard let names = value as? [String], !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy(council.seats.contains) else {
            throw Refusal(exit: 64, message: "usage: seats must be seats of the council")
        }
        return council.seats.filter(names.contains)
    }

    /// `synthesize` asks a council with no synthesizer for a written summary anyway; absent means not asked.
    static func synthesizeFlag(_ value: Any?) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Refusal(exit: 64, message: "usage: synthesize must be true or false")
        }
        return number.boolValue
    }

    static func capOverride(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), (1...86_400).contains(number.intValue) else {
            throw Refusal(exit: 64, message: "usage: cap must be a whole number of seconds")
        }
        return number.intValue
    }
}
