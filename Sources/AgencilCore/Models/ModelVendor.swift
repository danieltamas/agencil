import Foundation

/// Who trained a model, in the vendor strings seats use (`SeatConfig` vendors): `anthropic`, `openai`, `google` ...
/// The model's own name decides first; the provider or id prefix is the fallback for names nobody here knows.
public enum ModelVendor {
    private static let byName: [(vendor: String, pattern: String)] = [
        ("anthropic", #"claude|opus|sonnet|haiku|^fable"#),
        ("openai", #"^(gpt|chatgpt|codex|davinci|whisper|tts|text-embedding|o[0-9])"#),
        ("google", #"gemini|gemma|palm|imagen|^veo"#),
        ("meta", #"llama"#),
        ("mistral", #"mistral|mixtral|codestral|pixtral|ministral|devstral|magistral"#),
        ("deepseek", #"deepseek"#),
        ("alibaba", #"qwen|qwq"#),
        ("zhipu", #"glm"#),
        ("xai", #"grok"#),
        ("nvidia", #"nemotron|nvidia"#),
        ("xiaomi", #"mimo"#),
        ("moonshot", #"kimi|moonshot"#),
        ("cohere", #"command|cohere"#),
        ("microsoft", #"^phi-"#),
    ]
    private static let byProvider: [String: String] = [
        "anthropic": "anthropic", "openai": "openai", "text-completion-openai": "openai", "gemini": "google",
        "vertex_ai": "google", "mistral": "mistral", "deepseek": "deepseek", "xai": "xai", "cohere": "cohere", "nvidia_nim": "nvidia",
    ]

    public static func of(model id: String, provider: String? = nil) -> String {
        let name = id.lowercased()
        let base = name.split(separator: "/").last.map(String.init) ?? name
        for (vendor, pattern) in byName where base.range(of: pattern, options: .regularExpression) != nil { return vendor }
        if let provider, let vendor = byProvider[provider] ?? byProvider[String(provider.prefix { $0 != "-" })] { return vendor }
        return sanitized(provider ?? name.split(separator: "/").first.map(String.init) ?? "")
    }

    /// The seat config's vendor spelling: a-z, 0-9 and dashes, 40 characters at most, never empty.
    private static func sanitized(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let trimmed = String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        return trimmed.isEmpty ? "other" : trimmed
    }
}
