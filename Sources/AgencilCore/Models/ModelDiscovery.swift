import Darwin
import Foundation

public struct OllamaModel: Equatable, Sendable {
    public let name: String
    public let digest: String
    public let size: Int64
    /// Memory the loaded model holds on the GPU; nil for a model that is only on disk.
    public let sizeVRAM: Int64?
}

public struct OllamaProbe: Equatable, Sendable {
    /// "ok" or "failed". A failed probe carries no models and never touches the digest history.
    public let health: String
    public let models: [OllamaModel]
    public let loadedModels: [OllamaModel]
    public let warnings: [String]
    public let failureReason: String?
}

/// Probes an Ollama endpoint with `/api/tags` and `/api/ps` and remembers each model's digest per endpoint, so a
/// model that was re-pushed under the same label is flagged once.
public struct ModelDiscovery: Sendable {
    private static let responseLimit = 4 * 1024 * 1024

    public init() {}

    /// Throws before any connection when the endpoint breaks `EndpointPolicy`. Cancellation propagates; every other
    /// failure of the endpoint is a `failed` probe.
    public func probeOllama(endpoint: String, digestStore: URL, timeout: Duration = .seconds(20)) async throws -> OllamaProbe {
        let base = try EndpointPolicy.validate(endpoint)
        // One deadline covers both requests and the history update.
        let deadline = ContinuousClock.now + timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let tags: Tags = try await fetch("api/tags", base: base, session: session, deadline: deadline)
            let processes: Tags = try await fetch("api/ps", base: base, session: session, deadline: deadline)
            let models = try tags.models.map { try $0.model() }
            let loaded = try processes.models.map { try $0.model() }
            // Two entries under one label would flip the stored digest on every probe and warn each time.
            guard Set(models.map(\.name)).count == models.count else { throw Failure.malformed }
            let warnings = try await DigestHistory(file: digestStore)
                .record(models, endpoint: base.absoluteString, deadline: deadline)
            return OllamaProbe(health: "ok", models: models, loadedModels: loaded, warnings: warnings, failureReason: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            return OllamaProbe(health: "failed", models: [], loadedModels: [], warnings: [], failureReason: String(describing: error))
        }
    }

    private struct Tags: Decodable {
        struct Item: Decodable {
            let name: String
            let digest: String
            let size: Int64
            let size_vram: Int64?

            func model() throws -> OllamaModel {
                guard !name.isEmpty, !digest.isEmpty, size >= 0, (size_vram ?? 0) >= 0 else { throw Failure.malformed }
                return OllamaModel(name: name, digest: digest, size: size, sizeVRAM: size_vram)
            }
        }
        let models: [Item]
    }

    private enum Failure: Error { case status(Int), tooLarge, malformed }

    /// Redirects are never followed: a 302 reaches the caller as a failed status, so a listener cannot send the
    /// probe (and the policy check) somewhere else.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func fetch<T: Decodable>(_ path: String, base: URL, session: URLSession,
                                     deadline: ContinuousClock.Instant) async throws -> T {
        let remaining = ContinuousClock.now.duration(to: deadline).seconds
        guard remaining > 0 else { throw URLError(.timedOut) }
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: remaining)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.responseLimit { throw Failure.tooLarge }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// `{"<endpoint>": {"<model>": "<digest>"}}`, replaced atomically under an exclusive lock so two probes cannot
/// lose each other's update or warn twice for one change.
private struct DigestHistory {
    let file: URL

    func record(_ models: [OllamaModel], endpoint: String, deadline: ContinuousClock.Instant) async throws -> [String] {
        let lock = open(file.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        // Never blocks a cooperative thread: a holder that does not let go ends this probe at its deadline.
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { flock(lock, LOCK_UN) }

        var warnings: [String] = []
        var history: [String: [String: String]] = [:]
        // Absent is a fresh start; unreadable is an error and leaves the file alone; corrupt is reset, loudly.
        var stored: Data?
        do { stored = try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { stored = nil }
        if let stored {
            if let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: stored) {
                history = decoded
            } else {
                warnings.append("digest history was unreadable and has been reset; label changes before now cannot be detected")
            }
        }
        var known = history[endpoint] ?? [:]
        for model in models {
            if let previous = known[model.name], previous != model.digest {
                warnings.append("\(model.name) changed under its label on \(endpoint): digest \(previous) is now \(model.digest)")
            }
            known[model.name] = model.digest
        }
        history[endpoint] = known
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(history).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
        return warnings
    }
}

private extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
