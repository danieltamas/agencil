import AgencilCore
import Foundation

/// A made-up but realistic catalog for the previews and the screenshots: public model names, invented prices.
enum DemoCatalog {
    static let age: TimeInterval = 7 * 60

    /// Input and output dollars per million tokens, from a cheap tier to a frontier one.
    private static let tiers: [(input: Double, output: Double)] = [(0.1, 0.4), (0.25, 2), (0.8, 4), (3, 15), (5, 25), (15, 75)]

    /// `provider`, the tier, the model names. Providers the demo list does not price get none.
    private static let families: [(provider: String, tier: Int, models: [String])] = [
        ("anthropic", 5, ["claude-opus-4-1", "claude-opus-4"]),
        ("anthropic", 3, ["claude-sonnet-4-5", "claude-sonnet-4", "claude-3-7-sonnet", "claude-3-5-sonnet"]),
        ("anthropic", 1, ["claude-haiku-4-5", "claude-3-5-haiku"]),
        ("openai", 4, ["gpt-5.5", "gpt-5", "o3", "o1", "gpt-4o"]),
        ("openai", 2, ["gpt-5-mini", "gpt-4.1", "o4-mini", "o3-mini", "gpt-4.1-mini"]),
        ("openai", 0, ["gpt-5-nano", "gpt-4.1-nano", "gpt-4o-mini"]),
        ("gemini", 3, ["gemini-2.5-pro", "gemini-1.5-pro"]),
        ("gemini", 1, ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-1.5-flash"]),
        ("gemini", 0, ["gemini-2.5-flash-lite"]),
        ("deepseek", 1, ["deepseek-v3", "deepseek-r1", "deepseek-coder"]),
        ("mistral", 2, ["mistral-large-latest", "codestral-latest", "mistral-medium-latest"]),
        ("mistral", 0, ["mistral-small-latest", "ministral-8b-latest"]),
        ("xai", 3, ["grok-4", "grok-3"]),
        ("xai", 1, ["grok-3-mini"]),
    ]
    /// Gateways that resell the same models under a prefix, which is why a real list has hundreds of rows.
    private static let gateways = ["bedrock/", "vertex_ai/", "azure/", "openrouter/", "together_ai/"]
    private static let open: [(provider: String, tier: Int, models: [String])] = [
        ("together_ai", 1, ["llama-3.3-70b-instruct", "llama-3.1-405b-instruct", "qwen3-coder-480b", "qwen2.5-72b-instruct", "glm-4.6"]),
        ("openrouter", 0, ["llama-3.1-8b-instruct", "qwen3-30b-a3b", "gemma-3-27b-it", "phi-4", "kimi-k2"]),
    ]

    static var prices: [PriceListEntry] {
        var entries: [PriceListEntry] = []
        func add(_ id: String, _ provider: String, _ tier: Int, cache: Bool) {
            let tier = tiers[tier]
            entries.append(PriceListEntry(id: id, provider: provider, price: ModelPrice(
                input: tier.input, output: tier.output, cacheRead: cache ? tier.input / 10 : nil, cacheWrite: provider == "anthropic" ? tier.input * 1.25 : nil)))
        }
        for family in families {
            for (index, model) in family.models.enumerated() {
                add(model, family.provider, family.tier, cache: family.provider != "mistral")
                // Each gateway carries some of the models, so the rows are not a clean grid.
                for (offset, prefix) in gateways.enumerated() where (index + offset + family.tier) % 2 == 0 {
                    add(prefix + model, prefix.dropLast().replacingOccurrences(of: "_ai", with: ""), family.tier, cache: false)
                }
            }
        }
        for family in open {
            for model in family.models { add("\(family.provider)/\(model)", family.provider, family.tier, cache: false) }
        }
        // Chat models the list names but does not price.
        for model in ["bedrock/amazon.nova-pro-v1:0", "bedrock/cohere.command-r-v1:0", "azure/gpt-5-preview", "openrouter/mistral/devstral-small"] {
            entries.append(PriceListEntry(id: model, provider: String(model.prefix { $0 != "/" }), price: nil))
        }
        return entries
    }

    static let harnessLists: [String: [String]] = [
        "opencode": ["opencode/nemotron-3.5-lightning-free", "opencode/glm-5.3-flash-free", "opencode/deepseek-v4.1-flash-free",
                     "opencode/mimo-v2.6-flash-free", "openai/gpt-5", "anthropic/claude-sonnet-4-5"],
        "codex": ["gpt-6.1-sol", "gpt-5.5", "gpt-5"],
        "ollama": ["gemma4:26b", "qwen3-coder:30b", "llama3.3:70b", "lumen-ft-coder:7b"],
    ]

    static let custom = [CustomModel(id: "lumen-ft-coder:7b", harness: "ollama", note: "fine-tune on the build box"),
                         CustomModel(id: "harbor-review-1", harness: "opencode")]

    static var catalog: ModelCatalog {
        ModelCatalog(prices: prices, harnessLists: harnessLists, custom: custom,
                     seats: DemoPanel.seatRows.map { .init(name: $0.id, model: $0.model) })
    }
}
