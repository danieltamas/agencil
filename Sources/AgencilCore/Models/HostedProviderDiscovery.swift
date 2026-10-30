import Foundation
import LocalAuthentication
import Security

/// Hosted providers are reported as "key present" or "key absent" by Keychain item name. The value of a key never
/// crosses this boundary: the lookup answers a Bool, and the log carries names only.
public enum HostedProviderDiscovery {
    /// A lookup that fails (Keychain locked, unreadable) throws; it is never read as "absent".
    public static func keyPresence(
        itemNames: [String],
        lookup: @Sendable (String) throws -> Bool,
        log: @Sendable (String) -> Void
    ) throws -> [String: Bool] {
        var presence: [String: Bool] = [:]
        for name in itemNames {
            let present = try lookup(name)
            presence[name] = present
            log("keychain item \(name): \(present ? "present" : "absent")")
        }
        return presence
    }

    public struct KeychainFailure: Error, CustomStringConvertible {
        public let item: String
        public let status: OSStatus
        public var description: String { "keychain lookup of \(item) failed (OSStatus \(status))" }
    }

    /// Asks the login Keychain whether a generic-password item with this service name exists. Attributes only: the
    /// secret is never requested and a prompt is never shown; an item that would need one is a failed lookup, not a present key.
    @Sendable public static func keychainItemExists(_ name: String) throws -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case let status: throw KeychainFailure(item: name, status: status)
        }
    }
}
