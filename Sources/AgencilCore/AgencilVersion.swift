import Foundation

/// The running build's version. bundle.sh embeds an Info.plist section in every binary, so the CLI copied
/// to ~/.local/bin still knows its version without the app bundle beside it.
public enum AgencilVersion {
    public static let unstamped = "0.0.0"

    public static func current(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? unstamped
    }
}
