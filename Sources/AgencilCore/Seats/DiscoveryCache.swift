import Foundation

/// Harness probes kept for ten minutes (docs/AGENT-API.md step 3); older than that, the next ask probes again.
final class DiscoveryCache: @unchecked Sendable {
    private static let lifetime: TimeInterval = 600
    private let lock = NSLock()
    private let refreshing = NSLock()
    private var probes: [String: HarnessProbe] = [:]
    private var taken: Date?
    /// Kinds whose last good probe stood in for a failed one at the latest refresh.
    private var carried: Set<String> = []

    /// The world the resolver sees. Probing starts at the first probe lookup, so a refused route costs no process runs.
    /// `preflight` is the seat's fresh standing (docs/U25-SPEC.md); without it only install and sign-in are judged.
    func world(environment: [String: String], home: URL, preflight: @escaping @Sendable (Seat) -> String? = { _ in nil }) -> ResolverWorld {
        let catalog = try? HarnessCatalog.embedded()
        return ResolverWorld(probe: { [self] kind in
                                 if let catalog { refreshIfStale(catalog, environment: environment, home: home, force: false) }
                                 return lock.withLock { probes[kind] }
                             },
                             statusless: Set(catalog?.entries.filter { $0.status == nil }.map(\.kind) ?? []),
                             ollamaProblem: { OllamaClient.problem(for: $0) }, preflight: preflight)
    }

    /// Every catalog harness in catalog order. `force` probes again; otherwise the cache serves while it is fresh.
    func snapshot(environment: [String: String], home: URL, force: Bool) -> [HarnessProbe] {
        marked(environment: environment, home: home, force: force).probes
    }

    /// `snapshot`, with the kinds whose result is an earlier probe standing in for one that failed at the latest
    /// refresh. Both are read under one lock, so a refresh in between cannot pair one refresh's probes with another's.
    func marked(environment: [String: String], home: URL, force: Bool) -> (probes: [HarnessProbe], carried: Set<String>) {
        guard let catalog = try? HarnessCatalog.embedded() else { return ([], []) }
        refreshIfStale(catalog, environment: environment, home: home, force: force)
        return lock.withLock { (catalog.entries.compactMap { probes[$0.kind] }, carried) }
    }

    /// One refresh at a time, and freshness is judged after waiting: callers that found the cache stale together
    /// share one probe instead of each probing, which would also spend a carried result on the second one.
    private func refreshIfStale(_ catalog: HarnessCatalog, environment: [String: String], home: URL, force: Bool) {
        refreshing.withLock {
            let fresh = lock.withLock { taken.map { Date().timeIntervalSince($0) < Self.lifetime } ?? false }
            if force || !fresh { refresh(catalog, environment: environment, home: home) }
        }
    }

    /// Superset's agent wrappers (`~/.superset/bin`, `~/.superset-<name>/bin`) re-run the real binary found on PATH.
    private static func isShimDirectory(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count >= 2 && components.last == "bin" && components[components.count - 2].hasPrefix(".superset")
    }

    private func refresh(_ catalog: HarnessCatalog, environment: [String: String], home: URL) {
        // A seat runs the real harness: a launcher shim that looks the binary up on PATH cannot find it from the sandbox.
        var directories = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
            .filter { !Self.isShimDirectory(String($0)) }.map { URL(fileURLWithPath: String($0)) }
        let user = FileManager.default.homeDirectoryForCurrentUser
        var known = [user.appendingPathComponent(".local/bin"), user.appendingPathComponent(".opencode/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        // With test seams on, a stub directory goes first and only PATH entries inside the Agencil home count,
        // so the real installs on the machine running the tests cannot leak in.
        if environment["AGENCIL_TEST_SEAMS"] == "1" {
            known = []
            directories = directories.filter { $0.path.hasPrefix(home.path + "/") }
            if let prefix = environment["AGENCIL_PATH_PREFIX"] { directories.insert(URL(fileURLWithPath: prefix), at: 0) }
        }
        let finished = DispatchSemaphore(value: 0)
        let box = ProbeBox()
        Task.detached { @Sendable [directories, known] in
            box.set((try? await HarnessDiscovery().discover(catalog: catalog, searchPath: directories,
                                                            knownInstallDirectories: known, environment: environment)) ?? [])
            finished.signal()
        }
        finished.wait()
        let found = box.value
        lock.withLock {
            (probes, carried) = Self.merge(previous: probes, fresh: Dictionary(found.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first }),
                                           carried: carried)
            taken = Date()
        }
    }

    /// An install still on disk whose version command failed this time is an unknown state, not a reason to run a
    /// seat on an older copy: the last good result for that one install stands for one more lifetime, beside what
    /// this probe found for the others. Carried once only, so an install that stays broken gives way at the next
    /// refresh; a newer install found meanwhile always wins.
    static func merge(previous: [String: HarnessProbe], fresh: [String: HarnessProbe], carried: Set<String>)
        -> (probes: [String: HarnessProbe], carried: Set<String>) {
        var merged = fresh, nowCarried: Set<String> = []
        for (kind, probe) in fresh {
            guard !carried.contains(kind), let last = previous[kind], let lastBest = last.executable, let lastVersion = last.version,
                  probe.paths.contains(lastBest), !probe.installs.contains(where: { $0.executable == lastBest }),
                  probe.version.map({ HarnessDiscovery.isNewer(lastVersion, than: $0) }) ?? true else { continue }
            let lastInstall = last.installs.first { $0.executable == lastBest }
                ?? HarnessProbe.Install(executable: lastBest, version: lastVersion, signedIn: last.signedIn)
            var kept = HarnessProbe(kind: kind, paths: probe.paths, executable: lastBest, version: lastVersion, signedIn: last.signedIn,
                                    probeStatus: last.probeStatus, chainSupport: last.chainSupport)
            kept.installs = probe.installs + [lastInstall]
            merged[kind] = kept
            nowCarried.insert(kind)
        }
        return (merged, nowCarried)
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var probes: [HarnessProbe] = []
    var value: [HarnessProbe] { lock.withLock { probes } }
    func set(_ new: [HarnessProbe]) { lock.withLock { probes = new } }
}
