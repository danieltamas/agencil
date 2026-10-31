import Foundation

/// Harness probes kept for ten minutes (docs/AGENT-API.md step 3); older than that, the next ask probes again.
final class DiscoveryCache: @unchecked Sendable {
    private static let lifetime: TimeInterval = 600
    private let lock = NSLock()
    private var probes: [String: HarnessProbe] = [:]
    private var taken: Date?

    /// The world the resolver sees. Probing starts at the first probe lookup, so a refused route costs no process runs.
    func world(environment: [String: String], home: URL) -> ResolverWorld {
        let catalog = try? HarnessCatalog.embedded()
        return ResolverWorld(probe: { [self] kind in
                                 let fresh = lock.withLock { taken.map { Date().timeIntervalSince($0) < Self.lifetime } ?? false }
                                 if !fresh, let catalog { refresh(catalog, environment: environment, home: home) }
                                 return lock.withLock { probes[kind] }
                             },
                             statusless: Set(catalog?.entries.filter { $0.status == nil }.map(\.kind) ?? []),
                             ollamaProblem: { OllamaClient.problem(for: $0) })
    }

    /// Every catalog harness in catalog order. `force` probes again; otherwise the cache serves while it is fresh.
    func snapshot(environment: [String: String], home: URL, force: Bool) -> [HarnessProbe] {
        guard let catalog = try? HarnessCatalog.embedded() else { return [] }
        let fresh = lock.withLock { taken.map { Date().timeIntervalSince($0) < Self.lifetime } ?? false }
        if force || !fresh { refresh(catalog, environment: environment, home: home) }
        return lock.withLock { catalog.entries.compactMap { probes[$0.kind] } }
    }

    private func refresh(_ catalog: HarnessCatalog, environment: [String: String], home: URL) {
        var directories = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let user = FileManager.default.homeDirectoryForCurrentUser
        var known = [user.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
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
            probes = Dictionary(found.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
            taken = Date()
        }
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var probes: [HarnessProbe] = []
    var value: [HarnessProbe] { lock.withLock { probes } }
    func set(_ new: [HarnessProbe]) { lock.withLock { probes = new } }
}
