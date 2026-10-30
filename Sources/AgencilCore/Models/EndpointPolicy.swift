import Darwin
import Foundation

/// Where a model endpoint may live. Plain http carries API keys and code, so it is allowed only to this Mac or to
/// the owner's tailnet; anything else must be https. Pure: no lookups, no connections.
public enum EndpointPolicy {
    public enum Refusal: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        case cleartext(host: String)
        case userinfo

        public var description: String {
            switch self {
            case .invalid(let reason): "endpoint refused: \(reason)"
            case .cleartext(let host):
                "endpoint refused: plain http to \(host) would send keys and code in clear; use localhost, a tailnet address (100.64.0.0/10) or https"
            case .userinfo: "endpoint refused: credentials in the URL are not allowed"
            }
        }
    }

    public static func validate(_ endpoint: String) throws -> URL {
        guard !endpoint.isEmpty, let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Refusal.invalid("not an http or https URL")
        }
        guard var host = components.host, !host.isEmpty else { throw Refusal.invalid("no host") }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // http is judged on the host first so a userinfo trick (http://100.64.0.1@evil.example) reads as what it is.
        if scheme == "http", !isLocalOrTailnet(host) { throw Refusal.cleartext(host: host) }
        guard components.user == nil, components.password == nil else { throw Refusal.userinfo }
        guard let url = components.url else { throw Refusal.invalid("not a valid URL") }
        return url
    }

    private static func isLocalOrTailnet(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let address = UInt32(bigEndian: v4.s_addr)
            // 127.0.0.1, and 100.64.0.0/10 (carrier-grade NAT range Tailscale hands out).
            return address == 0x7F00_0001 || address & 0xFFC0_0000 == 0x6440_0000
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
        }
        return false
    }
}
