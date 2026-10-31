import Foundation

/// What a hosted seat is never shown (docs/U6-SPEC.md "Redaction rules"): files named like secrets, files the repo
/// lists in `.agencilignore`, and files whose text looks like a credential. Local seats see everything.
/// Every step that cannot be completed fails the ask: an unscanned file is never assumed clean.
struct Redaction {
    static let incomplete = Refusal(exit: 4, message: "failed: the redaction rules could not be applied")

    private static let namePatterns = [".env", ".env.*", "*.pem", "*.key", "*.p12", "*.keystore", "id_rsa*", "id_ed25519*",
                                       "id_ecdsa*", ".npmrc", ".netrc", ".git-credentials", "credentials*", "*secret*", "*token*",
                                       ".ssh", ".aws"]
    private static let contentLimit = 1_048_576
    private static let contentPatterns: [NSRegularExpression] = [
        "-----BEGIN [A-Z ]*PRIVATE KEY-----", "AKIA[0-9A-Z]{16}", "gh[pousr]_[A-Za-z0-9]{20,}", "github_pat_", "xox[baprs]-",
        "sk-[A-Za-z0-9_-]{20,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Patterns of the repo's `.agencilignore`: directory patterns (a trailing slash) apart from file globs.
    private let ignored: [(pattern: String, directory: Bool)]

    init(ignoreFile: String? = nil) {
        ignored = (ignoreFile ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                let directory = line.hasSuffix("/")
                var pattern = directory ? String(line.dropLast()) : line
                if pattern.hasPrefix("/") { pattern.removeFirst() }
                return (pattern, directory)
            }
    }

    /// The rules of a repo copy: its `.agencilignore` when it has one. A file that exists but cannot be read as text
    /// fails the ask, since its rules would silently be lost.
    init(copy: URL) throws {
        let file = copy.appendingPathComponent(".agencilignore")
        // A link or special file is not an ignore list: reading through it could leave the copy or never end.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) } catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError else { throw Self.incomplete }
            self.init()
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? .max) <= 1_048_576,
              let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else {
            throw Self.incomplete
        }
        self.init(ignoreFile: text)
    }

    private static func glob(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, FNM_CASEFOLD) == 0
    }

    /// Whether any part of the path is named like a secret.
    static func namedLikeSecret(_ path: String) -> Bool {
        path.split(separator: "/").contains { part in namePatterns.contains { glob($0, String(part)) } }
    }

    /// Whether the path, relative to the repo root, is withheld by name or by the repo's `.agencilignore`;
    /// `isDirectory` says whether its last part is one.
    func matches(relativePath: String, isDirectory: Bool = false) -> Bool {
        Self.namedLikeSecret(relativePath) || ignores(relativePath: relativePath, isDirectory: isDirectory)
    }

    /// The repo's own rules, tried on every part of the path and on every leading path of it.
    private func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let directory = index < parts.count - 1 || isDirectory
            let leading = parts[...index].joined(separator: "/")
            for rule in ignored where directory || !rule.directory {
                if Self.glob(rule.pattern, part) || Self.glob(rule.pattern, leading) { return true }
            }
        }
        return false
    }

    /// Whether the text carries a credential. Larger files than the limit are not scanned. Text in a wider encoding is
    /// read as well, with its zero bytes dropped, so UTF-16 and UTF-32 files are no way round the patterns.
    static func holdsCredential(_ data: Data) -> Bool {
        guard data.count <= contentLimit else { return false }
        var views = [String(decoding: data, as: UTF8.self)]
        if data.contains(0) { views.append(String(decoding: data.filter { $0 != 0 }, as: UTF8.self)) }
        return views.contains { text in
            let range = NSRange(text.startIndex..., in: text)
            return contentPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
        }
    }

    private static func resolved(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// An attachment is judged by its name, every directory above it, the file a link points at, and its text.
    /// `base` is the repo it may sit in: the repo's own ignore rules apply to the path below it, in whichever
    /// spelling (as given, or with links resolved) puts it inside the repo.
    func withholds(attachment path: String, text: String, base: String? = nil) -> Bool {
        let paths = [path, Self.resolved(path)]
        if paths.contains(where: Self.namedLikeSecret) || Self.holdsCredential(Data(text.utf8)) { return true }
        guard let base else { return false }
        for root in [base, Self.resolved(base)] {
            for candidate in paths where candidate.hasPrefix(root + "/") {
                if ignores(relativePath: String(candidate.dropFirst(root.count + 1)), isDirectory: false) { return true }
            }
        }
        return false
    }

    /// Removes what the rules withhold from an exported copy. Anything that cannot be listed, read or removed fails.
    func sweep(copy: URL) throws {
        let manager = FileManager.default
        var pending = [""]
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? copy : copy.appendingPathComponent(relative)
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { throw Self.incomplete }
            for name in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let url = copy.appendingPathComponent(path)
                guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { throw Self.incomplete }
                let type = attributes[.type] as? FileAttributeType
                let isDirectory = type == .typeDirectory
                var withheld = matches(relativePath: path, isDirectory: isDirectory)
                // A link's target is never read: its own name is all the rules can judge.
                if !withheld, type == .typeRegular, (attributes[.size] as? Int ?? 0) <= Self.contentLimit {
                    guard let data = manager.contents(atPath: url.path) else { throw Self.incomplete }
                    withheld = Self.holdsCredential(data)
                }
                if withheld {
                    do { try manager.removeItem(at: url) } catch { throw Self.incomplete }
                } else if isDirectory {
                    pending.append(path)
                }
            }
        }
    }
}
