import Darwin
import Foundation

/// Admission of one exchange: process cap, budget, memory floor, then a place among the running seats. Every
/// step fails closed and runs before any process or request exists.
extension Broker {
    static let unboundedOutputTokens = 4096

    /// What the exchange can cost: a bounded seat (one model request) at its worst, anything else as an estimate.
    static func quote(_ seat: Seat, prompt: String) -> Quote {
        let bytes = prompt.utf8.count
        if seat.harness == "ollama" {
            let output = seat.capTokens ?? unboundedOutputTokens
            let dollars = Double(bytes) / 1e6 * seat.price.inputPerMillion + Double(output) / 1e6 * seat.price.outputPerMillion
            return Quote(dollars: dollars, tokens: bytes + output, seconds: seat.capSeconds, bounded: true)
        }
        return Quote(dollars: 0, tokens: bytes / 4 + unboundedOutputTokens, seconds: seat.capSeconds, bounded: false)
    }

    /// Steps 1 to 3 for one candidate seat. On success the reservation row and the process-cap place are held.
    func admit(_ seat: Seat, requested: String, caller: String, parent: CapabilityRun?, prompt: String,
               config: SeatConfig) throws -> Admitted {
        let id = "rs_" + UUID().uuidString.lowercased()
        let quote = Self.quote(seat, prompt: prompt)
        let rootKey = try parent.flatMap { try budgets.reservation(thread: $0.thread, seq: $0.seq)?.rootKey } ?? caller
        let matching = BudgetStore.matching(config.budgets, route: requested, root: rootKey, vendor: seat.harness)
        guard capacity.enter(id, parentExchange: parent.map { "\($0.thread)-\($0.seq)" }, isProcess: seat.harness != "ollama",
                             limits: config.limits, orphans: try orphanCount()) else {
            throw Refusal(exit: 3, message: "refused: busy")
        }
        do {
            if let refusal = try budgets.admit(id: id, quote: quote, budgets: matching, routeKey: requested, rootKey: rootKey,
                                               vendor: seat.harness, commit: true) {
                capacity.leave(id)
                throw refusal
            }
            if config.limits.memoryFloorMB > 0, freeMemoryMB().map({ $0 < config.limits.memoryFloorMB }) != false {
                try? budgets.release(id)
                capacity.leave(id)
                throw Refusal(exit: 3, message: "refused: memory")
            }
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            try? budgets.release(id)
            capacity.leave(id)
            throw error
        }
        return Admitted(id: id, quote: quote)
    }

    /// Step 4: waits up to `wait` seconds for one of the "seats at once" places; the reservation goes back when none frees.
    func awaitSeat(_ admitted: Admitted, limits: Limits, wait: Int) throws {
        let deadline = Date().addingTimeInterval(Double(wait))
        while true {
            let orphans: Int
            do { orphans = try orphanCount() } catch {
                abandon(admitted)
                throw error
            }
            if capacity.activate(admitted.id, limits: limits, orphans: orphans) { return }
            if Date() >= deadline {
                abandon(admitted)
                throw Refusal(exit: 3, message: "refused: busy")
            }
            usleep(20_000)
        }
    }

    /// An admission that never reached an exchange gives back its reservation and its places.
    func abandon(_ admitted: Admitted) {
        try? budgets.release(admitted.id)
        capacity.leave(admitted.id)
    }

    /// Seat processes of a dead broker that are still alive: they hold places until their group is proven empty.
    /// An unreadable ledger is an error, never zero: occupancy is not assumed away.
    private func orphanCount() throws -> Int {
        let open = Set(try store.open().map(\.id))
        return tracking.withLock { startupOrphans.intersection(open).count }
    }

    /// Free plus inactive memory in MB; nil when the kernel does not say. Tests replace it under the seams.
    private func freeMemoryMB() -> Int? {
        if environment["AGENCIL_TEST_SEAMS"] == "1", let injected = environment["AGENCIL_TEST_FREE_MEMORY_MB"] { return Int(injected) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = UInt64(info.free_count) + UInt64(info.inactive_count)
        return Int(pages * UInt64(sysconf(_SC_PAGESIZE)) / 1_048_576)
    }

    // MARK: settling

    /// Ends an exchange: the charge is settled first, so a client that sees the answer also sees what it cost.
    func finishExchange(thread: String, seq: Int, state: Exchange.State, answer: String?, reason: String?,
                        usage: (dollars: Double, tokens: Int)? = nil, runStatus: String? = nil) {
        // A charge that cannot be written stays reserved in full, and the next start settles it (settleOrphans).
        let reported = usage ?? reportedUsage(thread: thread, seq: seq)
        for attempt in 0..<3 {
            if (try? budgets.settle(thread: thread, seq: seq, reported: reported)) != nil { break }
            if attempt < 2 { usleep(50_000) }
        }
        try? threads.finish(thread: thread, seq: seq, state: state, answer: answer, reason: reason, runStatus: runStatus)
        capacity.leave(exchange: "\(thread)-\(seq)")
        removeCopy(thread: thread, seq: seq)
    }

    /// A process seat reports what it used in `usage.json` of its run directory; anything malformed is not a report.
    private func reportedUsage(thread: String, seq: Int) -> (dollars: Double, tokens: Int)? {
        let file = directory.appendingPathComponent("runs/\(thread)-\(seq)/usage.json")
        guard let data = try? Data(contentsOf: file), data.count <= 4096,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dollars = SeatConfig.number(object["dollars"]), dollars >= 0,
              let tokens = SeatConfig.whole(object["tokens"]), (0...OllamaClient.countLimit).contains(tokens) else { return nil }
        return (dollars, tokens)
    }

    /// The `reserved` and `cost` fields of an exchange's reply.
    func costFields(thread: String, seq: Int) -> [String: Any] {
        guard let found = try? budgets.reservation(thread: thread, seq: seq) else { return [:] }
        var fields: [String: Any] = ["reserved": ["dollars": found.reserved.dollars, "tokens": found.reserved.tokens,
                                                  "seconds": found.reserved.seconds]]
        if let charged = found.charged {
            fields["cost"] = ["dollars": charged.dollars, "tokens": charged.tokens, "basis": found.basis ?? "reserved"]
        }
        return fields
    }

    // MARK: observability

    /// The `budgets` op: every configured budget with what it has spent and what is set aside.
    func budgetsOp() -> [String: Any] {
        let config: SeatConfig
        do { config = try SeatConfig(values: try ConfigStore(directory: directory).read().values) } catch let problem as ConfigProblem {
            return Self.failure(problem.message, exit: 4)
        } catch {
            return Self.failure(error.localizedDescription, exit: 70)
        }
        var rows: [[String: Any]] = []
        for budget in config.budgets {
            guard let used = try? ledger.locked({ try budgets.usage(of: budget) }) else {
                return Self.failure("the budget ledger cannot be read", exit: 70)
            }
            rows.append(["name": budget.name, "scope": budget.scope.rawValue, "key": budget.key, "window": budget.window.rawValue,
                         "hard": budget.hard, "dollars_limit": budget.dollars ?? NSNull(), "tokens_limit": budget.tokens ?? NSNull(),
                         "spent_dollars": used.spentDollars, "spent_tokens": used.spentTokens,
                         "reserved_dollars": used.reservedDollars, "reserved_tokens": used.reservedTokens])
        }
        return ["ok": true, "data": ["budgets": rows]]
    }
}
