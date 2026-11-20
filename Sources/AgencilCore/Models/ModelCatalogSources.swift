import Foundation

/// What each installed harness reports about its own models, read from the output of its own commands.
public enum ModelCatalogSources {
    public enum Failure: Error, LocalizedError, Equatable {
        case notInstalled(String)
        case commandFailed(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let program): "\(program) is not installed"
            case .commandFailed(let detail): detail
            case .unreadable(let detail): "its model list could not be read: \(detail)"
            }
        }
    }

    /// `opencode models` prints one `provider/model` per line. A line that is not that shape (a warning, a banner)
    /// is skipped; a listing with no such line at all is a failure, not an empty list.
    public static func parseOpencode(_ output: Data) throws -> [String] {
        let ids = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count <= 160 && $0.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:@+-]*/[A-Za-z0-9._:/@+-]+\z"#, options: .regularExpression) != nil }
        guard !ids.isEmpty else { throw Failure.unreadable("no provider/model lines") }
        return Array(Set(ids)).sorted()
    }

    /// `codex debug models` prints `{"models":[{"slug":...,"visibility":"list"|"hide"}]}`; hidden models are not offered.
    public static func parseCodex(_ output: Data) throws -> [String] {
        struct Listing: Decodable {
            struct Item: Decodable { let slug: String; let visibility: String? }
            let models: [Item]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: output) else { throw Failure.unreadable("not the expected JSON") }
        let ids = listing.models.filter { $0.visibility == "list" && !$0.slug.isEmpty && $0.slug.count <= 160 }.map(\.slug)
        guard !ids.isEmpty else { throw Failure.unreadable("no listed models") }
        return Array(Set(ids)).sorted()
    }

    /// Runs `argv` and returns its stdout. The program is found on `directories`; not found is `notInstalled`.
    public static func run(_ argv: [String], directories: [URL], runner: ProcessRunner = ProcessRunner()) async throws -> Data {
        guard let program = argv.first else { throw Failure.notInstalled("?") }
        // Every copy is a candidate and the newest wins, as for a seat: a stale copy earlier on the list must not.
        let candidates = HarnessDiscovery.unique(directories.map { $0.appendingPathComponent(program).path })
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard let found = try await HarnessDiscovery.newest(candidates, program: program, runner: runner) else {
            throw Failure.notInstalled(program)
        }
        let output: ProcessOutput
        do { output = try await runner.run([found] + argv.dropFirst(), timeout: .seconds(20), gracePeriod: .milliseconds(100)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.commandFailed("\(program) did not finish: \(error)") }
        guard output.status == 0 else { throw Failure.commandFailed("\(program) exited with status \(output.status)") }
        return output.stdout
    }

    /// PATH first, then where an app started at login (a short PATH) still finds the usual installs.
    public static func searchDirectories(environment: [String: String]) -> [URL] {
        let path = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        return path + HarnessDiscovery.knownInstallDirectories(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
