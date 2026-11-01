import Foundation

/// The running build's version. bundle.sh embeds an Info.plist section in every binary, so the CLI copied
/// to ~/.local/bin still knows its version without the app bundle beside it.
public enum AgencilVersion {
    public static let unstamped = "0.0.0"
    /// The Info.plist key a build from a checkout stamps with `git describe` (scripts/bundle.sh).
    public static let sourceKey = "AgencilSource"

    public static func current(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? unstamped
    }

    public static func source(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        infoDictionary?[sourceKey] as? String
    }

    /// `v0.1.0 + 3 commits (abc1234), built from source, uncommitted changes`, from the bundle's version and the
    /// `git describe` the installer stamps into Info.plist.
    public static func line(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        var source = source(infoDictionary: infoDictionary)
        let dirty = source?.hasSuffix("-dirty") ?? false
        if dirty { source?.removeLast("-dirty".count) }
        var line = "v" + current(infoDictionary: infoDictionary)
        if let source, let match = source.wholeMatch(of: /v?(\d+\.\d+\.\d+)(?:-(\d+)-g([0-9a-f]+))?/) {
            line = "v\(match.1)"
            if let commits = match.2.flatMap({ Int($0) }), commits > 0 { line += " + \(commits) commit\(commits == 1 ? "" : "s")" }
            if let commit = match.3 { line += " (\(commit))" }
        } else if let source, !source.isEmpty {
            line += " (\(source))"
        }
        if infoDictionary?[sourceKey] != nil { line += ", built from source" }
        if dirty { line += ", uncommitted changes" }
        return line
    }
}
