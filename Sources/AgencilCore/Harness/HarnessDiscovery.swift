import Darwin
import Foundation

/// Finds the catalog's harnesses and asks each one, through its own non-interactive commands, what it is. Probes
/// of different kinds run concurrently and each has its own deadline, so one hung binary never delays the rest.
public struct HarnessDiscovery: Sendable {
    private static let gracePeriod = Duration.milliseconds(100)

    public init() {}

    public func discover(
        catalog: HarnessCatalog,
        searchPath: [URL],
        knownInstallDirectories: [URL],
        environment: [String: String],
        probeTimeout: Duration = .seconds(20)
    ) async throws -> [HarnessProbe] {
        let directories = Self.unique((searchPath + knownInstallDirectories).map(\.path))
        return try await withThrowingTaskGroup(of: (Int, HarnessProbe).self) { group in
            for (index, entry) in catalog.entries.enumerated() {
                let paths = directories.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.executable) }
                    .filter { Self.isExecutable($0.path) }
                group.addTask {
                    (index, await Self.probe(entry, paths: paths, environment: environment, timeout: probeTimeout))
                }
            }
            var results: [(Int, HarnessProbe)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func probe(_ entry: HarnessCatalog.Entry, paths: [URL], environment: [String: String],
                              timeout: Duration) async -> HarnessProbe {
        func result(version: String? = nil, executable: URL? = nil, signedIn: SignInState, status: ProbeStatus,
                    chain: ChainSupport = .untested) -> HarnessProbe {
            HarnessProbe(kind: entry.kind, paths: paths, executable: executable, version: version, signedIn: signedIn,
                         probeStatus: status, chainSupport: chain)
        }
        guard !paths.isEmpty else {
            return result(signedIn: .unknown(reason: "not installed"), status: .failed(reason: "not installed"))
        }
        // The newest install is the one a user gets by upgrading; a stale copy earlier on the path does not win.
        var best: (path: URL, version: String)?
        var installs: [HarnessProbe.Install] = []
        var firstFailure: ProbeStatus?
        for path in paths {
            switch await run([path.path] + entry.versionArguments, environment: environment, timeout: timeout) {
            case .success(let output):
                guard output.status == 0, let version = parseVersion(output.stdout) else {
                    firstFailure = firstFailure ?? .failed(reason: "version command failed")
                    continue
                }
                let state = await signIn(entry, executable: path, environment: environment, timeout: timeout).0
                installs.append(.init(executable: path, version: version, signedIn: state))
                if best == nil || isNewer(version, than: best!.version) { best = (path, version) }
            case .failure(let status): firstFailure = firstFailure ?? status
            }
        }
        guard let best else {
            return result(signedIn: .unknown(reason: "version probe did not succeed"), status: firstFailure ?? .failed(reason: "version command failed"))
        }
        let (signedIn, status) = await signIn(entry, executable: best.path, environment: environment, timeout: timeout)
        let chain = await chainSupport(entry, executable: best.path, environment: environment, timeout: timeout)
        var probe = result(version: best.version, executable: best.path, signedIn: signedIn, status: status, chain: chain)
        probe.installs = installs
        return probe
    }

    // MARK: sign-in

    private static func signIn(_ entry: HarnessCatalog.Entry, executable: URL, environment: [String: String],
                               timeout: Duration) async -> (SignInState, ProbeStatus) {
        guard let status = entry.status else {
            return (.unknown(reason: "no non-interactive status command"), .ok)
        }
        switch await run([executable.path] + status.arguments, environment: environment, timeout: timeout) {
        case .failure(.timedOut): return (.unknown(reason: "status command timed out"), .timedOut)
        case .failure(let failure): return (.unknown(reason: "status command did not run"), failure)
        case .success(let output):
            let text = normalized(String(decoding: output.stdout, as: UTF8.self) + output.stderr)
            let saysIn = text.contains(normalized(status.signedInOutput))
            let saysOut = text.contains(normalized(status.signedOutOutput))
            // Contradictory text is judged before the exit code can pick a side; a state needs its text and its
            // exit code, and an unknown state is never treated as signed in.
            if saysIn && saysOut {
                return (.unknown(reason: "status output claims both states"), .failed(reason: "status output claims both states"))
            }
            if saysIn && output.status == status.signedInExitCode { return (.signedIn, .ok) }
            if saysOut && output.status == status.signedOutExitCode { return (.signedOut, .ok) }
            let reason = "unrecognized status output (exit \(output.status))"
            return (.unknown(reason: reason), .failed(reason: reason))
        }
    }

    // MARK: chain

    private static func chainSupport(_ entry: HarnessCatalog.Entry, executable: URL, environment: [String: String],
                                     timeout: Duration) async -> ChainSupport {
        guard let probe = entry.chainProbe else { return .untested }
        let marker = UUID().uuidString
        let arguments = probe.arguments.map { $0.replacingOccurrences(of: "{server}", with: probe.server) }
        let env = environment.merging(["AGENCIL_CHAIN_MARKER": marker]) { _, new in new }
        guard case .success(let output) = await run([executable.path] + arguments, environment: env, timeout: timeout),
              output.status == 0,
              let reported = reportedMarker(output.stdout) else { return .untested }
        return reported == marker ? .supported : .unsupported
    }

    /// The first stdout line that is a JSON-RPC response carrying `result.marker`.
    private static func reportedMarker(_ stdout: Data) -> String? {
        for line in String(decoding: stdout, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let marker = result["marker"] as? String else { continue }
            return marker
        }
        return nil
    }

    // MARK: helpers

    private static func run(_ argv: [String], environment: [String: String],
                            timeout: Duration) async -> Result<ProcessOutput, ProbeStatus> {
        do {
            return .success(try await ProcessRunner().run(argv, environment: environment, timeout: timeout,
                                                          gracePeriod: gracePeriod))
        } catch ProcessRunner.Failure.timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.failed(reason: String(describing: error)))
        }
    }

    private static func isExecutable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// The first dotted number on the first non-empty line ("codex-cli 0.5.1" gives "0.5.1"), else that line.
    private static func parseVersion(_ stdout: Data) -> String? {
        let text = String(decoding: stdout, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let range = line.range(of: #"\d+(\.\d+)+[0-9A-Za-z.+-]*"#, options: .regularExpression)
        return range.map { String(line[$0]) } ?? line
    }

    /// Release precedence: a prerelease ("1.0.0-beta.2") is older than its release; otherwise numbers, then text.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func split(_ version: String) -> (core: [Int], pre: String?) {
            let end = version.firstIndex(where: { $0 == "-" || $0 == "+" }) ?? version.endIndex
            let core = version[..<end].split(separator: ".").compactMap { Int($0) }
            let pre = end < version.endIndex && version[end] == "-" ? String(version[version.index(after: end)...]) : nil
            return (core, pre)
        }
        let a = split(candidate), b = split(current)
        for index in 0..<max(a.core.count, b.core.count) {
            let left = index < a.core.count ? a.core[index] : 0, right = index < b.core.count ? b.core[index] : 0
            if left != right { return left > right }
        }
        switch (a.pre, b.pre) {
        case (nil, .some): return true
        case (.some(let left), .some(let right)): return left.compare(right, options: .numeric) == .orderedDescending
        default: return false
        }
    }
}
