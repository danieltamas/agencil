import Foundation

/// The network of a confined seat whose commands inherit the broker's profile (docs/U38-SPEC.md): the profile allows
/// one loopback port, and the proxy behind it connects only to the hosts listed here.
enum Egress {
    /// Constants, never config: a host added here is a host every steered command of that harness can reach.
    /// Codex: the subscription endpoint, the API-key endpoint and the login refresh.
    private static let vendorHosts: [String: Set<String>] = ["codex": ["chatgpt.com", "api.openai.com", "auth.openai.com"]]

    /// Nil for a harness that keeps its own network rules and is not proxied.
    static func hosts(for harness: String) -> Set<String>? { vendorHosts[harness] }

    /// Both spellings of each variable, because tools disagree on which one they read. An inherited NO_PROXY would
    /// send some hosts around the proxy, where the profile blocks them, so it is emptied.
    static func environment(port: Int) -> [String: String] {
        let proxy = "http://127.0.0.1:\(port)"
        var variables = ["NO_PROXY": "", "no_proxy": ""]
        for name in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
            variables[name] = proxy
            variables[name.lowercased()] = proxy
        }
        return variables
    }
}
