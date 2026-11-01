import Darwin
import Foundation

/// The model catalog's cache and its refresh: `model-catalog.json` under the Agencil home, written atomically.
/// A source that fails keeps what the cache already holds for it; nothing here ever empties the cache.
public struct ModelCatalogService: Sendable {
    public struct Cache: Equatable, Codable, Sendable {
        public var priceEntries: [PriceListEntry] = []
        public var pricesUpdatedAt: Date?
        /// Model ids each harness reported, by harness name.
        public var harnessLists: [String: [String]] = [:]
        public var harnessesUpdatedAt: Date?

        public init() {}
    }

    public struct Report: Equatable, Sendable {
        /// One plain sentence per source that could not be read; the cache kept its old content for it.
        public var notes: [String] = []
    }

    /// Runs `argv` and returns its stdout; the seam tests replace.
    public typealias Command = @Sendable ([String]) async throws -> Data
    /// The model names one Ollama endpoint reports.
    public typealias OllamaLister = @Sendable (String) async throws -> [String]
    public typealias PriceDownload = @Sendable () async throws -> Data

    private let file: URL
    private let command: Command
    private let ollama: OllamaLister
    private let download: PriceDownload

    public init(directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                command: Command? = nil, ollama: OllamaLister? = nil, download: @escaping PriceDownload = { try await ModelPriceList.fetch() }) {
        file = directory.appendingPathComponent("model-catalog.json")
        let directories = ModelCatalogSources.searchDirectories(environment: environment)
        self.command = command ?? { try await ModelCatalogSources.run($0, directories: directories) }
        self.ollama = ollama ?? { endpoint in
            let probe = try await ModelDiscovery().probeOllama(endpoint: endpoint, digestStore: directory.appendingPathComponent("model-catalog-digests.json"))
            guard probe.health == "ok" else { throw ModelCatalogSources.Failure.commandFailed(probe.failureReason ?? "no answer") }
            return probe.models.map(\.name)
        }
        self.download = download
    }

    /// An absent file is an empty cache; a file that cannot be read or decoded is an error, so a damaged cache is seen.
    public func load() throws -> Cache {
        let data: Data
        do { data = try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { return Cache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Cache.self, from: data)
    }

    public func isStale(_ cache: Cache, now: Date = .now) -> Bool {
        ModelPriceList.isStale(updatedAt: cache.pricesUpdatedAt, now: now) || ModelPriceList.isStale(updatedAt: cache.harnessesUpdatedAt, now: now)
    }

    /// Reads every source, keeps what each source returned and writes once. A failed source is a note, not an error.
    /// `endpoints` are the Ollama endpoints the configured seats name.
    public func refresh(endpoints: [String], now: Date = .now) async throws -> Report {
        var cache = (try? load()) ?? Cache()
        var report = Report()
        do {
            let fresh = try ModelPriceList.parse(try await download())
            try ModelPriceList.checkContinuity(fresh, against: cache.priceEntries)
            cache.priceEntries = fresh
            cache.pricesUpdatedAt = now
        } catch is CancellationError { throw CancellationError() }
        catch { report.notes.append("price list: \(error.localizedDescription)") }

        var reported = false
        for (harness, argv, parse) in [("opencode", ["opencode", "models"], ModelCatalogSources.parseOpencode),
                                       ("codex", ["codex", "debug", "models"], ModelCatalogSources.parseCodex)] {
            do {
                cache.harnessLists[harness] = try parse(try await command(argv))
                reported = true
            } catch is CancellationError { throw CancellationError() }
            catch { report.notes.append("\(harness): \(error.localizedDescription)") }
        }
        var names = Set<String>(), answered = false, missed = false
        for endpoint in endpoints {
            do {
                names.formUnion(try await ollama(endpoint))
                answered = true
            } catch is CancellationError { throw CancellationError() }
            catch {
                missed = true
                report.notes.append("ollama \(endpoint): \(error.localizedDescription)")
            }
        }
        if answered {
            // An endpoint that did not answer keeps the names it had.
            if missed { names.formUnion(cache.harnessLists["ollama"] ?? []) }
            cache.harnessLists["ollama"] = names.sorted()
            reported = true
        }
        if reported { cache.harnessesUpdatedAt = now }
        try save(cache)
        return report
    }

    private func save(_ cache: Cache) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cache).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}
