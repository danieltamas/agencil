// U4 public API contract:
// EndpointPolicy.validate(_ endpoint: String) throws -> URL (pure, no I/O).
// ModelDiscovery.init(); probeOllama(endpoint: String, digestStore: URL,
// timeout: Duration = .seconds(20)) async throws -> OllamaProbe.
// OllamaProbe: health: String ("ok"/"failed"), models: [OllamaModel],
// loadedModels: [OllamaModel], warnings: [String]. OllamaModel: name: String,
// digest: String, size: Int64, sizeVRAM: Int64? (loaded models).
// Policy refusal throws before any network request, including redirects.
// The digestStore JSON is persisted across ModelDiscovery instances. Failed or
// malformed responses cannot replace the last successfully observed digest.
// HostedProviderDiscovery.keyPresence(itemNames: [String],
// lookup: @Sendable (String) throws -> Bool,
// log: @Sendable (String) -> Void) throws -> [String: Bool].
// Lookup asks only if the named Keychain item exists, never requests its value.
// Existing helpers: AcceptanceDirectory.init(), .url, .remove().
import Foundation
import Network
import Testing
import AgencilCore

@Suite struct ModelDiscoveryAcceptanceTests {
    @Test func endpointPolicyAllowsOnlyExplicitSafeHostsOrTLS() throws {
        for endpoint in ["http://localhost:11434", "http://127.0.0.1:11434",
                         "http://[::1]:11434", "http://100.64.0.0:11434",
                         "http://100.127.255.255:11434", "https://example.com"] {
            #expect(try EndpointPolicy.validate(endpoint).host != nil)
        }
        for endpoint in ["http://100.63.255.255", "http://100.128.0.0",
                         "http://192.0.2.10:11434", "http://example.com",
                         "http://100.64.0.1@evil.example/", "http://localhost.evil.example/"] {
            do {
                _ = try EndpointPolicy.validate(endpoint)
                Issue.record("Unsafe endpoint accepted: \(endpoint)")
            } catch {
                let reason = String(describing: error).lowercased()
                #expect(reason.contains("keys") && reason.contains("code") && reason.contains("clear"))
            }
        }
        for endpoint in ["", "garbage", "http://", "http:///", "https://",
                         "file:///tmp/model", "ftp://localhost", "http://[::1",
                         "https://user:password@example.com", "http://localhost@evil.example"] {
            #expect(throws: (any Error).self) { try EndpointPolicy.validate(endpoint) }
        }
    }

    @Test func probesHealthModelsMemoryAndPersistsOneWarningPerDigestChange() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let server = try OllamaAcceptanceServer()
        defer { server.stop() }
        let store = temp.url.appendingPathComponent("digests.json")
        let first = try await ModelDiscovery().probeOllama(endpoint: server.endpoint,
            digestStore: store, timeout: .seconds(30))
        #expect(first.health == "ok")
        #expect(first.warnings.isEmpty)
        let model = try #require(first.models.first)
        #expect(first.models.count == 1)
        #expect(model.name == "qwen3:32b")
        #expect(model.digest == "sha256:AAAA")
        #expect(model.size == 20_000_000_000)
        let loaded = try #require(first.loadedModels.first)
        #expect(first.loadedModels.count == 1)
        #expect(loaded.name == model.name)
        #expect(loaded.size == 20_000_000_000)
        #expect(loaded.sizeVRAM == 18_000_000_000)
        #expect(FileManager.default.fileExists(atPath: store.path))
        server.setDigest("sha256:BBBB")
        let second = try await ModelDiscovery().probeOllama(endpoint: server.endpoint,
            digestStore: store, timeout: .seconds(30))
        #expect(second.models.first?.digest == "sha256:BBBB")
        #expect(second.warnings.count == 1)
        #expect(second.warnings.first?.contains("changed under its label") == true)
        #expect(second.warnings.first?.contains("qwen3:32b") == true)
        let third = try await ModelDiscovery().probeOllama(endpoint: server.endpoint,
            digestStore: store, timeout: .seconds(30))
        #expect(third.warnings.isEmpty)
        #expect(server.paths.filter { $0 == "/api/tags" }.count == 3)
        #expect(server.paths.filter { $0 == "/api/ps" }.count == 3)
    }

    @Test func failedAndMalformedResponsesFailClosedWithoutPoisoningDigests() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let server = try OllamaAcceptanceServer()
        defer { server.stop() }
        let store = temp.url.appendingPathComponent("digests.json")
        let initial = try await ModelDiscovery().probeOllama(endpoint: server.endpoint,
            digestStore: store, timeout: .seconds(30))
        try #require(initial.health == "ok", "Digest baseline requires a successful probe: \(initial.failureReason ?? "unknown")")
        let baseline = try Data(contentsOf: store)
        for mode in [OllamaAcceptanceServer.Mode.unavailable, .malformed] {
            server.setMode(mode)
            do {
                let result = try await ModelDiscovery().probeOllama(endpoint: server.endpoint,
                    digestStore: store, timeout: .seconds(30))
                #expect(result.health == "failed")
            } catch { /* Throwing also fails closed. */ }
            #expect(try Data(contentsOf: store) == baseline)
        }
    }

    @Test func refusedEndpointNeverConnectsAndRedirectCannotBypassPolicy() async throws {
        let temp = try AcceptanceDirectory()
        defer { temp.remove() }
        let server = try OllamaAcceptanceServer()
        defer { server.stop() }
        let store = temp.url.appendingPathComponent("digests.json")
        // This socket is live, but userinfo is forbidden even on a loopback host.
        let refused = server.endpoint.replacingOccurrences(of: "http://", with: "http://user:secret@")
        do {
            _ = try await ModelDiscovery().probeOllama(endpoint: refused,
                digestStore: store, timeout: .seconds(30))
            Issue.record("Discovery bypassed endpoint policy")
        } catch { #expect(!String(describing: error).isEmpty) }
        #expect(server.connections == 0)
        #expect(!FileManager.default.fileExists(atPath: store.path))
        // Redirecting to a forbidden URL pointing at another live local listener
        // must also be refused before that listener receives a connection.
        let target = try OllamaAcceptanceServer()
        defer { target.stop() }
        server.setMode(.redirect(target.endpoint.replacingOccurrences(of: "http://", with: "http://user@")))
        do {
            let result = try await ModelDiscovery().probeOllama(endpoint: server.endpoint,
                digestStore: store, timeout: .seconds(30))
            #expect(result.health == "failed")
        } catch { /* Rejecting all redirects is also acceptable. */ }
        #expect(target.connections == 0)
    }

    @Test func hostedPresenceRequestsNamesOnlyAndFailsClosedOnLookupError() throws {
        let calls = ModelAcceptanceCapture()
        let logs = ModelAcceptanceCapture()
        let secret = "fixture-secret-never-returned-or-logged"
        let result = try HostedProviderDiscovery.keyPresence(itemNames: ["harbor-key", "lumen-key"],
            lookup: { name in
                calls.append(name)
                // A value exists in the fake vault, but cannot cross this Bool boundary.
                let vault = ["harbor-key": secret]
                return vault[name] != nil
            }, log: { logs.append($0) })
        #expect(result == ["harbor-key": true, "lumen-key": false])
        #expect(calls.values.sorted() == ["harbor-key", "lumen-key"])
        #expect(!logs.values.joined().contains(secret))
        #expect(!String(describing: result).contains(secret))
        enum VaultFailure: Error { case unavailable }
        #expect(throws: VaultFailure.self) {
            try HostedProviderDiscovery.keyPresence(itemNames: ["harbor-key"],
                lookup: { _ in throw VaultFailure.unavailable }, log: { logs.append($0) })
        }
    }
}

private final class ModelAcceptanceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

// Real loopback HTTP boundary. All state is locked; stop cancels and drains the
// serial queue so no listener or accepted connection outlives the test.
private final class OllamaAcceptanceServer: @unchecked Sendable {
    enum Mode { case normal, unavailable, malformed, redirect(String) }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "acceptance.ollama")
    private let lock = NSLock()
    private var digest = "sha256:AAAA"
    private var mode = Mode.normal
    private var requests: [String] = []
    private var accepted = 0
    private var clients: [NWConnection] = []
    var endpoint: String { "http://127.0.0.1:\(listener.port!.rawValue)" }
    var connections: Int { lock.withLock { accepted } }
    var paths: [String] { lock.withLock { requests } }
    func setDigest(_ value: String) { lock.withLock { digest = value } }
    func setMode(_ value: Mode) { lock.withLock { mode = value } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.accepted += 1; self.clients.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 30) == .success, listener.port != nil else {
            listener.cancel()
            throw ServerFailure.startup
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            bytes.append(data ?? Data())
            let request = String(decoding: bytes, as: UTF8.self)
            if request.contains("\r\n\r\n") {
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let (digest, mode) = self.lock.withLock {
                    self.requests.append(path)
                    return (self.digest, self.mode)
                }
                self.respond(connection, path: path, digest: digest, mode: mode)
            } else if done || error != nil || bytes.count > 32768 {
                connection.cancel()
            } else { self.receive(connection, accumulated: bytes) }
        }
    }

    private func respond(_ connection: NWConnection, path: String, digest: String, mode: Mode) {
        var status = "200 OK", extra = "", body: String
        switch mode {
        case .unavailable: status = "503 Unavailable"; body = "{}"
        case .malformed: body = "not-json"
        case .redirect(let target): status = "302 Found"; extra = "Location: \(target)\r\n"; body = ""
        case .normal:
            if path == "/api/tags" {
                body = """
                {"models":[{"name":"qwen3:32b","model":"qwen3:32b","digest":"\(digest)",
                "size":20000000000,"modified_at":"2026-01-01T00:00:00Z"}]}
                """
            } else if path == "/api/ps" {
                body = """
                {"models":[{"name":"qwen3:32b","model":"qwen3:32b","digest":"\(digest)",
                "size":20000000000,"size_vram":18000000000,"expires_at":"2099-01-01T00:00:00Z"}]}
                """
            } else { status = "404 Not Found"; body = "{}" }
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n" +
            extra + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    func stop() {
        listener.cancel()
        lock.withLock { clients.forEach { $0.cancel() } }
        queue.sync {}
    }
    private enum ServerFailure: Error { case startup }
}
