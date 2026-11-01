import Foundation

/// The documented seat catalog (docs/U25-SPEC.md "Presets"): enabled from Settings > Seats or `agencil seats add
/// --preset <name>`, through the same validated config path as a hand-filled sheet. Nothing is written until asked.
public struct SeatPreset: Sendable, Equatable {
    public let name: String
    public let harness: String
    public let model: String
    public let vendor: String
    public let plan: Seat.Plan
    public let endpoint: String?
    public let hosted: Bool
    public let capSeconds: Int
    public let note: String

    public static let all: [SeatPreset] = [
        SeatPreset(name: "gpt-codex", harness: "codex", model: "gpt-6.1-sol", vendor: "openai", plan: .subscription, endpoint: nil,
                   hosted: true, capSeconds: 1200, note: "ChatGPT subscription; the preflight reads its usage limit"),
        SeatPreset(name: "claude-opus", harness: "claude", model: "opus", vendor: "anthropic", plan: .subscription, endpoint: nil,
                   hosted: true, capSeconds: 1200, note: "recused on Claude-authored briefs; the synthesizer by default"),
        SeatPreset(name: "nemotron-free", harness: "opencode", model: "opencode/nemotron-3.5-lightning-free", vendor: "nvidia", plan: .free,
                   endpoint: nil, hosted: true, capSeconds: 600, note: "OpenCode Zen free tier"),
        SeatPreset(name: "glm-free", harness: "opencode", model: "opencode/glm-5.3-flash-free", vendor: "zhipu", plan: .free,
                   endpoint: nil, hosted: true, capSeconds: 600, note: "OpenCode Zen free tier"),
        SeatPreset(name: "deepseek-free", harness: "opencode", model: "opencode/deepseek-v4.1-flash-free", vendor: "deepseek", plan: .free,
                   endpoint: nil, hosted: true, capSeconds: 600, note: "OpenCode Zen free tier"),
        SeatPreset(name: "mimo-free", harness: "opencode", model: "opencode/mimo-v2.6-flash-free", vendor: "xiaomi", plan: .free,
                   endpoint: nil, hosted: true, capSeconds: 600, note: "OpenCode Zen free tier; the spare"),
        SeatPreset(name: "ollama-local", harness: "ollama", model: "gemma4:26b", vendor: "google", plan: .local,
                   endpoint: "http://127.0.0.1:11434", hosted: false, capSeconds: 300, note: "local pre-screen, never a voting seat"),
    ]

    public static func named(_ name: String) -> SeatPreset? { all.first { $0.name == name } }

    /// The draft `ConfigEditor.add` validates and writes.
    public var draft: SeatDraft {
        SeatDraft(name: name, harness: harness, model: model, endpoint: endpoint, pin: nil, capSeconds: capSeconds,
                  vendor: vendor, plan: plan.rawValue, hosted: hosted)
    }

    /// One line of `agencil seats presets`.
    public var line: String { "\(name)  \(harness)  \(model)  \(vendor)  \(plan.rawValue)  \(capSeconds)s  \(note)" }
}
