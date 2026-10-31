import AgencilCore
import Foundation
import Testing

/* API contract (public symbols in AgencilCore).
 ConfigEditor.init(directory: URL, beforeUpdate: (@Sendable () throws -> Void)? = nil).
 beforeUpdate is a deterministic concurrency seam: called after read/validation,
 before ConfigStore.update(expectedRevision:), outside the store lock.
 add(_ draft: SeatDraft/CouncilDraft/RouteDraft) throws -> ConfigSnapshot;
 set(_ key: String, _ value: String) throws -> ConfigSnapshot.
 SeatDraft.init(name: String, harness: String, model: String,
                endpoint: String? = nil, pin: String? = nil, capSeconds: Int? = nil).
 CouncilDraft.init(name: String, seats: [String], rule: String, quorum: Int? = nil).
 RouteDraft.init(callers: [String], target: String, hopLimit: Int? = nil).
 Drafts are Sendable values. SheetProblems: Error, Equatable, fields: [String: String].
 All refusals, including revision conflict, are SheetProblems; unassigned errors use form.
 AgentAccess.init(home: URL, environment: [String: String]);
 state(_ harness: String), install(_ harness: String), uninstall(_ harness: String)
 throws -> AccessState. AccessState has harness: String, installed: Bool,
 path: String?, entry: String?, problem: String?. AccessError: Error,
 init(message: String), message: String. No asynchronous API is needed.
 */

final class U9Rig {
    let home: BrokerHome
    let store: ConfigStore
    let editor: ConfigEditor
    var file: URL { home.url.appendingPathComponent("config.json") }
    init() throws {
        home = try BrokerHome()
        store = ConfigStore(directory: home.url)
        editor = ConfigEditor(directory: home.url)
        _ = try store.update {
            $0 = ["seats": try! u6aText([u6aSeat("a")]), "aliases": "{\"alias-a\":\"a\"}",
                  "councils": "[{\"name\":\"panel\",\"seats\":[\"a\"]}]",
                  "routes": "[]", "unrelated": "retain this exact value"]
        }
    }
    func bytes() throws -> Data { try Data(contentsOf: file) }
    func refuses(_ keys: Set<String>, _ operation: () throws -> ConfigSnapshot) throws {
        let before = try bytes(), snapshot = try store.read()
        do { _ = try operation(); Issue.record("Invalid draft was accepted") }
        catch let error as SheetProblems {
            #expect(Set(error.fields.keys) == keys)
            #expect(error.fields.values.allSatisfy { !$0.isEmpty })
        }
        #expect(try bytes() == before)
        #expect(try store.read() == snapshot)
    }
}

struct U9AccessFixture {
    let home: BrokerHome
    let file: URL
    let original: Data
    let access: AgentAccess
    init(_ harness: String) throws {
        home = try BrokerHome()
        file = home.url.appendingPathComponent(harness == "codex" ? "codex/config.toml" : "opencode/opencode.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        original = Data((harness == "codex" ? "# retain comment\nowner = \"maya\"\n" : "{\n  \"owner\": \"maya\"\n}\n").utf8)
        try original.write(to: file)
        access = AgentAccess(home: home.url, environment: ["AGENCIL_MCP_CONFIG_DIR": home.url.path])
    }
    func bytes() throws -> Data { try Data(contentsOf: file) }
    func assertEntry(_ state: AccessState, harness: String) throws {
        #expect(state.harness == harness && state.installed && state.problem == nil)
        #expect(state.path == file.path)
        let entry = try #require(state.entry)
        #expect(!entry.isEmpty)
        let text = String(decoding: try bytes(), as: UTF8.self)
        if harness == "codex" {
            #expect(text.contains(entry))
            #expect(entry.contains("agencil") && entry.contains("--caller"))
        } else {
            let actual = try #require((brokerJSON(bytes())["mcp"] as? [String: Any])?["agencil"] as? [String: Any])
            let reported = try brokerJSON(Data(entry.utf8))
            #expect(NSDictionary(dictionary: actual).isEqual(to: reported))
        }
    }
}
