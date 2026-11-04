import Darwin
import Foundation

/// Which socket a request came in on (docs/U32-SPEC.md): the owner door serves everything, the agent door only what an
/// agent needs and never the owner's label.
enum Door { case owner, agent }

/// What a caller that is not the owner may attach: a file whose opened path lies inside `top` and outside `denied`.
struct AttachPolicy {
    let top: String
    let denied: [String]

    func allows(_ path: String) -> Bool {
        Self.within(path, top) && !denied.contains { Self.within(path, $0) }
    }

    static func within(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
}

extension Broker {
    /// What an agent may ask of the broker over the agent door.
    static let agentOps: Set<String> = ["ping", "ask", "wake", "result", "status", "stop", "list_targets"]
    /// Folders and files that hold credentials, browser profiles or the broker's own state: never attached, and no repo
    /// that contains one is attached either, whatever the peer's working directory.
    private static let credentialPaths = [".ssh", ".aws", ".gnupg", ".config", ".claude", ".codex", ".agencil", ".netrc", ".npmrc",
                                          ".pypirc", ".git-credentials", ".docker", ".kube", "Library/Keychains",
                                          "Library/Application Support", "Library/Cookies", "Library/Safari"]

    /// A refusal for a request that the door, the access switch or ownership does not admit; nil when it may go on.
    func admit(_ op: String, _ request: [String: Any], peer: Int32?, peerStart: Double?, door: Door) -> [String: Any]? {
        let label = request["caller"] as? String
        // `status` and `stop` with a `run` name a launch (the broker's own bookkeeping, owner door only).
        let launchRun = ["status", "stop"].contains(op) && request["run"] != nil && request["id"] == nil
        if door == .agent {
            // A seat's process that says "owner" stays the seat that started it (Origin.child), so the claim gains nothing.
            if label == "owner", !isSeatChild(request, peer: peer, peerStart: peerStart) {
                return Self.failure("refused: the owner calls on the owner socket", exit: 3)
            }
            guard Self.agentOps.contains(op), !launchRun else { return Self.failure("refused: not served on the agent socket", exit: 3) }
        }
        guard Self.agentOps.contains(op), op != "ping", !launchRun else { return nil }
        let identity: String
        switch callerIdentity(request, peer: peer, peerStart: peerStart) {
        case .failure(let refusal): return Self.failure(refusal.message, exit: refusal.exit)
        case .success(let found): identity = found
        }
        if identity == "owner" { return nil }
        guard (try? ConfigStore(directory: directory).read().values["agent_access"]) == "on" else {
            return Self.failure("refused: agent access is off", exit: 3)
        }
        return ownershipRefusal(op, request, identity: identity)
    }

    private func isSeatChild(_ request: [String: Any], peer: Int32?, peerStart: Double?) -> Bool {
        if case .success(.child) = attribute(peer: peer, peerStart: peerStart, capability: request["cap"] as? String) { return true }
        return false
    }

    /// "owner" only for a root connection that says so; a seat's process is the seat that started it, whatever it claims.
    /// A connection whose ancestry or capability cannot be established is refused, never given the name it claims.
    private func callerIdentity(_ request: [String: Any], peer: Int32?, peerStart: Double?) -> Result<String, Refusal> {
        switch attribute(peer: peer, peerStart: peerStart, capability: request["cap"] as? String) {
        case .success(.child(let run)): return .success(run.seat)
        case .success(.root): return .success(request["caller"] as? String ?? "unknown")
        case .failure(let refusal): return .failure(refusal)
        }
    }

    /// A thread belongs to the caller that asked it, a sitting to the caller that woke it. A sitting may be read by any
    /// caller with access on (a shared `agencil://sitting/<id>` link), never stopped by one. Only a thread or a sitting
    /// is an agent's to follow: any other id (a launch) is refused, whichever field names it.
    private func ownershipRefusal(_ op: String, _ request: [String: Any], identity: String) -> [String: Any]? {
        let notYours = Self.failure("refused: not your thread", exit: 3)
        if op == "ask" {
            // A follow-up (`ask` with a thread) continues someone's conversation, so it is theirs to continue.
            guard let id = request["thread"] as? String else { return nil }
            guard let thread = try? threads.thread(id: id) else { return nil }
            return thread.caller == identity ? nil : notYours
        }
        guard ["result", "status", "stop"].contains(op) else { return nil }
        let named = [request["id"], request["run"]].compactMap { $0 as? String }
        // Two different names for one request could pass this check on one and act on the other.
        guard named.count <= 1 || Set(named).count == 1, let id = named.first else {
            return named.isEmpty ? nil : Self.failure("refused: ambiguous id", exit: 3)
        }
        if id.hasPrefix("th_") {
            guard let thread = try? threads.thread(id: id) else { return nil }
            return thread.caller == identity ? nil : notYours
        }
        if id.hasPrefix("sit_") {
            guard op == "stop" else { return nil }
            let wokenBy = (try? sittingRows.caller(of: id)) ?? nil
            return wokenBy == identity ? nil : notYours
        }
        return Self.failure("refused: not served to agents", exit: 3)
    }

    /// For a request that names files or a repo and does not come from the owner: the policy every file is judged by when
    /// it is opened (inside the git top level of the peer's working directory, as the kernel reports it, outside the
    /// credential locations), after the repo itself is judged here. Nothing is read.
    func attachPolicy(_ request: [String: Any], peer: Int32?) throws -> AttachPolicy? {
        let files = (request["files"] as? [String]) ?? []
        let repo = request["repo"] as? String
        guard !files.isEmpty || repo != nil else { return nil }
        // The broker's own trigger loop (its own process, the owner's configured repo) is not a caller to bind.
        if peer == getpid(), request["caller"] as? String == "trigger" { return nil }
        let refusal = Refusal(exit: 3, message: "refused: file outside the caller's repo")
        guard let peer, let cwd = ProcessTable.workingDirectory(of: peer), let top = Self.gitTop(of: cwd) else { throw refusal }
        let homePath = Confinement.home(environment: environment)
        let home = Self.resolved(homePath) ?? homePath
        // A repository that holds the home folder holds every credential in it.
        guard !AttachPolicy.within(home, top) else { throw refusal }
        let denied = Self.credentialPaths.flatMap { name -> [String] in
            let literal = home + "/" + name
            return [literal, Self.resolved(literal)].compactMap { $0 }
        }
        let policy = AttachPolicy(top: top, denied: denied)
        // The whole list is judged before any file is opened; the open then judges the file it really got.
        for file in files {
            guard file.hasPrefix("/"), let real = Self.resolved(file), policy.allows(real) else { throw refusal }
        }
        if let repo {
            guard repo.hasPrefix("/"), let real = Self.resolved(repo), policy.allows(real),
                  !denied.contains(where: { AttachPolicy.within($0, real) }) else { throw refusal }
        }
        return policy
    }

    private static func resolved(_ path: String) -> String? {
        guard let found = realpath(path, nil) else { return nil }
        defer { free(found) }
        return String(cString: found)
    }

    /// The top of the git work tree that holds `path`, by git itself (a bare `.git` marker is not a repository).
    private static func gitTop(of path: String) -> String? {
        guard let real = resolved(path), let top = RepoCopy.output(["-C", real, "rev-parse", "--show-toplevel"]), !top.isEmpty else { return nil }
        return resolved(top)
    }
}
