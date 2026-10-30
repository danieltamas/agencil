import Foundation

/// Synthetic data for screenshots and layout tests: made-up repos, people and seats, a fixed clock. Nothing here
/// comes from this Mac or from any real project (docs/DESIGN.md "Screenshots and demo data").
enum DemoStore {
    /// 2026-10-25 14:30 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_938_600)

    static let repos = ["harbor/checkout", "lumen/api", "orbit/web"]
    static let people = ["maya", "jonas", "lee"]
    static let seats = ["codex-gpt", "claude-opus", "opencode-kimi", "hermes-qwen", "box-qwen3"]

    /// The longest values the layout must hold: a 48-character repo, a 60-character model id, a 120-character reason.
    static let longRepo = "northwind-platform/customer-checkout-experience-ui"
    static let longModelId = "registry.example.invalid/community/qwen3-coder-480b-a35b-instruct-q4_K_M"
    static let longReason = "The seat did not answer within its time limit because the remote endpoint closed the connection twice while the answer was streaming."
}
