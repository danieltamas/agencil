import Foundation

/// The address an owner hands to another agent so it can read a sitting or a thread: `agencil://sitting/sit_...` or
/// `agencil://thread/th_...`. The link carries only the record id; what the agent may read still depends on its routes.
public enum SittingLink {
    public static let scheme = "agencil"

    /// The link for a record id: a sitting (`sit_`) or a thread (`th_`); nil for anything else.
    public static func link(for id: String) -> String? {
        if id.hasPrefix("sit_") { return "\(scheme)://sitting/\(id)" }
        if id.hasPrefix("th_") { return "\(scheme)://thread/\(id)" }
        return nil
    }

    /// The record id inside a link. Fails closed: anything that is not exactly `agencil://<sitting|thread>/<id>` (extra
    /// path parts, a query, a fragment, credentials, a port, a mismatched id kind) comes back unchanged, and an
    /// unchanged value is never a record id the broker routes, so a malformed link acts on nothing.
    public static func id(from value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), parts.scheme == scheme, let host = parts.host,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              let prefix = ["sitting": "sit_", "thread": "th_"][host], parts.path.hasPrefix("/") else { return value }
        let id = String(parts.path.dropFirst())
        let safe = id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return safe && id.hasPrefix(prefix) && id.count > prefix.count ? id : value
    }
}
