import Foundation

/// Where an ask or a wake came from: the calling process's working directory reduced to its git top-level folder name and
/// path, home abbreviated (`agencil  ~/Sites/agencil`). Computed by the CLI or `agencil mcp` and stored in the local
/// ledger only; it is never sent anywhere.
public enum ProjectLabel {
    public static func label(cwd: String, home: String = NSHomeDirectory()) -> String? {
        guard cwd.hasPrefix("/") else { return nil }
        var top = URL(fileURLWithPath: cwd).standardizedFileURL
        let manager = FileManager.default
        var cursor = top
        while cursor.path != "/" {
            if manager.fileExists(atPath: cursor.appendingPathComponent(".git").path) { top = cursor; break }
            cursor = cursor.deletingLastPathComponent()
        }
        let path = top.path.hasPrefix(home) ? "~" + top.path.dropFirst(home.count) : top.path
        return "\(top.lastPathComponent)  \(path)"
    }

    /// The broker keeps a label only when it is short printable text; anything else is "not recorded".
    static func clean(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= 300,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return text
    }
}
