import Foundation
import Testing
@testable import AgencilCore

/// The model catalog against a fixture price list and a fake command runner: no network, no process.
@Suite(.serialized) struct ModelCatalogTests {
    /// 60 chat models: claude and gpt priced, a few shapes the parser must treat with care.
    private func fixture() -> Data {
        var root: [String: Any] = ["sample_spec": ["litellm_provider": "x", "mode": "chat"]]
        for number in 0..<30 {
            root["claude-demo-\(number)"] = ["litellm_provider": "anthropic", "mode": "chat", "input_cost_per_token": 3e-06,
                                             "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07,
                                             "cache_creation_input_token_cost": 3.75e-06]
            root["gpt-demo-\(number)"] = ["litellm_provider": "openai", "mode": "chat", "input_cost_per_token": 2.5e-07,
                                          "output_cost_per_token": 2e-06]
        }
        root["image-model"] = ["litellm_provider": "openai", "mode": "image_generation", "input_cost_per_token": 1e-06]
        root["unpriced-chat"] = ["litellm_provider": "bedrock", "mode": "chat"]
        root["negative-price"] = ["litellm_provider": "bedrock", "mode": "chat", "input_cost_per_token": -1.0, "output_cost_per_token": 1e-06]
        root["bad-cache"] = ["litellm_provider": "bedrock", "mode": "chat", "input_cost_per_token": 1e-06,
                             "output_cost_per_token": 1e-06, "cache_read_input_token_cost": "free"]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test func priceListIsPerMillionAndNeverInvented() throws {
        let entries = try ModelPriceList.parse(fixture())
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(byId["claude-demo-1"]?.price == ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75))
        #expect(byId["gpt-demo-1"]?.price == ModelPrice(input: 0.25, output: 2, cacheRead: nil, cacheWrite: nil))
        #expect(byId["image-model"] == nil && byId["sample_spec"] == nil)
        #expect(byId["unpriced-chat"] != nil && byId["unpriced-chat"]?.price == nil)
        #expect(byId["negative-price"]?.price == nil)
        #expect(byId["bad-cache"]?.price == nil)
    }

    @Test func aBrokenListIsRefused() {
        #expect(throws: ModelPriceList.Failure.self) { try ModelPriceList.parse(Data("[]".utf8)) }
        #expect(throws: ModelPriceList.Failure.self) { try ModelPriceList.parse(Data(#"{"claude-x":{"litellm_provider":"anthropic","mode":"chat"}}"#.utf8)) }
    }

    @Test func harnessListingsParse() throws {
        let opencode = Data("opencode/big-pickle\nWARN something\nopenai/gpt-5.5\nopencode/big-pickle\n".utf8)
        #expect(try ModelCatalogSources.parseOpencode(opencode) == ["openai/gpt-5.5", "opencode/big-pickle"])
        #expect(throws: ModelCatalogSources.Failure.self) { try ModelCatalogSources.parseOpencode(Data("nothing here\n".utf8)) }
        let codex = Data(#"{"models":[{"slug":"gpt-demo","visibility":"list"},{"slug":"gpt-hidden","visibility":"hide"}]}"#.utf8)
        #expect(try ModelCatalogSources.parseCodex(codex) == ["gpt-demo"])
        #expect(throws: ModelCatalogSources.Failure.self) { try ModelCatalogSources.parseCodex(Data("{}".utf8)) }
    }

    @Test func vendorsUseTheSeatSpelling() {
        #expect(ModelVendor.of(model: "claude-opus-4-1") == "anthropic")
        #expect(ModelVendor.of(model: "opencode/glm-5.3-flash-free") == "zhipu")
        #expect(ModelVendor.of(model: "o3-mini") == "openai")
        #expect(ModelVendor.of(model: "mystery-1", provider: "Acme Cloud") == "acme-cloud")
        #expect(ModelVendor.of(model: "mystery-1") == "mystery-1")
    }

    @Test func mergeJoinsSourcesAndKeepsPricesHonest() throws {
        let prices = try ModelPriceList.parse(fixture())
        let catalog = ModelCatalog(prices: prices, harnessLists: ["opencode": ["openai/gpt-demo-1", "opencode/big-pickle"]],
                                   custom: [CustomModel(id: "claude-demo-1", harness: "aider", note: "gateway"), CustomModel(id: "my-model", harness: "goose")],
                                   seats: [.init(name: "reviewer", model: "claude-demo-1")])
        let byId = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        let claude = try #require(byId["claude-demo-1"])
        #expect(claude.harnesses == ["aider", "claude"] && claude.sources == [.custom, .priceList])
        #expect(claude.inUseBy == ["reviewer"] && claude.note == "gateway" && claude.vendor == "anthropic")
        #expect(byId["openai/gpt-demo-1"]?.price?.input == 0.25)
        #expect(byId["opencode/big-pickle"]?.price == nil)
        #expect(byId["sonnet"]?.harnesses == ["claude"] && byId["sonnet"]?.price == nil)
        #expect(byId["my-model"]?.isCustom == true)
        #expect(catalog.ids(for: "opencode") == ["openai/gpt-demo-1", "opencode/big-pickle"])
    }

    private func home() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct Down: Error {}

    @Test func refreshCachesAndAFailureKeepsTheCache() async throws {
        let directory = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = fixture()
        let working = ModelCatalogService(directory: directory, command: { argv in
            argv.first == "opencode" ? Data("opencode/big-pickle\n".utf8) : Data(#"{"models":[{"slug":"gpt-demo","visibility":"list"}]}"#.utf8)
        }, ollama: { _ in ["gemma-demo:7b"] }, download: { data })
        let report = try await working.refresh(endpoints: ["http://127.0.0.1:11434"])
        #expect(report.notes.isEmpty)
        let cache = try working.load()
        #expect(cache.priceEntries.count == 63 && cache.harnessLists["ollama"] == ["gemma-demo:7b"] && cache.harnessLists["codex"] == ["gpt-demo"])
        #expect(!working.isStale(cache))

        let broken = ModelCatalogService(directory: directory, command: { _ in throw Down() }, ollama: { _ in throw Down() }, download: { throw Down() })
        let failed = try await broken.refresh(endpoints: ["http://127.0.0.1:11434"])
        #expect(failed.notes.count == 4)
        #expect(try broken.load() == cache)

        let halved = ModelCatalogService(directory: directory, command: { _ in throw Down() }, ollama: { _ in [] }, download: {
            var small = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            for key in small.keys.filter({ $0.hasPrefix("gpt-demo-") }) { small[key] = nil }
            for key in small.keys.filter({ $0.hasPrefix("claude-demo-") }).prefix(28) { small[key] = nil }
            return try JSONSerialization.data(withJSONObject: small)
        })
        let report2 = try await halved.refresh(endpoints: [])
        #expect(report2.notes.contains { $0.hasPrefix("price list:") })
        #expect(try halved.load().priceEntries == cache.priceEntries)
    }

    @Test func aDamagedCacheIsAnErrorNotAnEmptyCatalog() throws {
        let directory = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("model-catalog.json"))
        #expect(throws: (any Error).self) { try ModelCatalogService(directory: directory).load() }
    }

    @Test func customModelsRoundTripThroughTheEditor() throws {
        let directory = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ConfigEditor(directory: directory)
        let model = CustomModel(id: "my-model:7b", harness: "ollama", note: "on the box")
        try editor.add(customModel: model)
        #expect(try editor.customModels() == [model])
        #expect(throws: SheetProblems.self) { try editor.add(customModel: model) }
        #expect(throws: SheetProblems.self) { try editor.add(customModel: CustomModel(id: "bad id", harness: "ollama")) }
        #expect(throws: SheetProblems.self) { try editor.add(customModel: CustomModel(id: "ok", harness: "nope")) }
        let renamed = CustomModel(id: "my-model:13b", harness: "ollama")
        try editor.update(customModel: model, with: renamed)
        #expect(try editor.customModels() == [renamed])
        try editor.remove(customModel: renamed)
        #expect(try editor.customModels().isEmpty)
        try ConfigStore(directory: directory).update { $0["custom_models"] = "{oops" }
        #expect(throws: SheetProblems.self) { try editor.customModels() }
    }
}
