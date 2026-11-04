import Darwin
import Foundation

/// Where a request comes from: a root (the owner, or a process outside every seat), or a seat run's child.
enum Origin {
    case root
    case child(of: CapabilityRun)
}

extension Broker {
    private static let walkLimit = 64

    /// Docs/AGENT-API.md "Chains, hops and loops": the process tree and the presented capability, judged together.
    /// Anything that cannot be established is a refusal, never a root.
    func attribute(peer: Int32?, peerStart: Double?, capability token: String?) -> Result<Origin, Refusal> {
        let unknown = Refusal(exit: 3, message: "refused: ancestry unknown")
        let injected = environment["AGENCIL_TEST_SEAMS"] == "1" ? environment["AGENCIL_TEST_FAIL_ANCESTRY"] : nil
        guard injected != "peer", let peer else { return .failure(unknown) }
        let tree: CapabilityRun?
        switch seatAncestor(of: peer, startedAt: peerStart, failing: injected == "walk") {
        case .failure: return .failure(unknown)
        case .success(let found): tree = found
        }
        if let token {
            let issued = (try? threads.capability(token: token)) ?? nil
            guard let issued, issued.live else { return .failure(Refusal(exit: 3, message: "refused: capability expired")) }
            guard issued.launchID == tree?.launchID else {
                return .failure(Refusal(exit: 3, message: "refused: capability does not match caller"))
            }
        }
        guard let tree else { return .success(.root) }
        guard tree.live else { return .failure(Refusal(exit: 3, message: "refused: capability expired")) }
        return .success(.child(of: tree))
    }

    /// Root or a refusal: a seat's child, or a caller whose ancestry cannot be established, is never a root.
    func attributeRoot(peer: Int32?, peerStart: Double?, capability token: String?) -> Result<Void, Refusal> {
        switch attribute(peer: peer, peerStart: peerStart, capability: token) {
        case .failure(let refusal): return .failure(refusal)
        case .success(.root): return .success(())
        case .success(.child): return .failure(Refusal(exit: 3, message: "refused: a seat cannot do this"))
        }
    }

    /// The seat run whose process group holds `pid` or one of its ancestors; nil when the walk reaches launchd first.
    private func seatAncestor(of pid: Int32, startedAt: Double?, failing: Bool) -> Result<CapabilityRun?, Refusal> {
        let unknown = Refusal(exit: 3, message: "refused: ancestry unknown")
        if failing { return .failure(unknown) }
        let runs = tracking.withLock { Array(tracked.values) }
        var current = pid
        for _ in 0..<Self.walkLimit {
            guard case .found(let entry) = ProcessTable.lookup(current) else { return .failure(unknown) }
            // The connection's process must still be the one that opened it, not a later holder of the same pid.
            if current == pid, entry.startTime != startedAt { return .failure(unknown) }
            if let run = runs.first(where: { ($0.pid == entry.pid || $0.pgid == entry.pgid) && $0.window.contains(entry.startTime) }) {
                // A launch that is not an ask has no chain to extend: its children count as roots.
                // A ledger that cannot answer is not "this launch was not an ask".
                guard let owner = try? threads.capability(launch: run.id) else { return .failure(unknown) }
                return .success(owner)
            }
            if entry.parent <= 1 { return .success(nil) }
            current = entry.parent
        }
        return .failure(unknown)
    }
}
