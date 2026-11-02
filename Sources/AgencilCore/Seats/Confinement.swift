import Foundation

/// Runs a seat that works on a repo copy inside an OS sandbox (docs/U6-SPEC.md "Confinement"): everything is denied
/// except what the seat needs, so a harness that wanders reads nothing of the owner's home, secrets or other repos.
/// The profile is written by the broker from paths the broker chose; nothing in it comes from the repo.
enum Confinement {
    static let systemExecutable = "/usr/bin/sandbox-exec"
    /// "/etc" is a link to "/private/etc": the link itself is read before it is followed, so both spellings are listed.
    private static let systemReadable = ["/usr", "/bin", "/sbin", "/System", "/Library", "/etc", "/private/etc", "/private/var/db", "/dev",
                                         "/private/var/select", "/Applications/Xcode.app", "/opt/homebrew", "/usr/local"]
    private static let harnessConfig: [String: [String]] = [
        "codex": [".codex"], "claude": [".claude", ".claude.json"], "opencode": [".config/opencode", ".local/share/opencode"],
        "hermes": [".hermes"],
    ]

    /// The sandbox launcher, or the refusal that stops the ask: a seat is never run unconfined instead.
    static func executable(environment: [String: String]) throws -> String {
        var path = systemExecutable
        if environment["AGENCIL_TEST_SEAMS"] == "1", let injected = environment["AGENCIL_TEST_SANDBOX_EXEC"] { path = injected }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw Refusal(exit: 4, message: "failed: confinement unavailable")
        }
        return path
    }

    /// The home the harness keeps its own configuration in.
    static func home(environment: [String: String]) -> String {
        if environment["AGENCIL_TEST_SEAMS"] == "1", let injected = environment["HOME"], injected.hasPrefix("/") { return injected }
        return NSHomeDirectory()
    }

    /// The path the kernel sees (/private/tmp, not /tmp): the sandbox matches resolved paths, and Foundation's own
    /// symlink resolution strips the /private prefix.
    private static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Every directory above `path`, root first: the walk to an allowed place is permitted, listing it is not.
    private static func ancestors(of path: String) -> [String] {
        var found = ["/"]
        var current = ""
        for part in path.split(separator: "/").dropLast() {
            current += "/" + part
            found.append(current)
        }
        return found
    }

    static func profile(copy: String, runDirectory: String, executable: String, harness: String, home: String) -> String {
        let named = [copy, runDirectory, (executable as NSString).deletingLastPathComponent]
            + (harnessConfig[harness] ?? []).map { home + "/" + $0 }
        let copy = real(copy), run = real(runDirectory)
        let reads = named.map(real) + systemReadable
        // The walk is allowed along both spellings of a path: a link such as /tmp is read before it is followed.
        let walk = Set((reads + named).flatMap(ancestors(of:))).sorted()
        let lines = [
            "(version 1)", "(deny default)",
            "(allow process-exec) (allow process-fork) (allow signal (target self)) (allow sysctl-read)",
            "(allow mach-lookup) (allow ipc-posix-shm) (allow network*)",
            "(allow file-read-metadata " + walk.map { "(literal \(quoted($0)))" }.joined(separator: " ") + ")",
            "(allow file-read* (literal \"/\") " + reads.map { "(subpath \(quoted($0)))" }.joined(separator: " ") + ")",
            "(allow file-write* (subpath \(quoted(run))) (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (literal \"/dev/tty\")"
                + " (regex #\"^/dev/(fd|ttys?)[0-9]*$\"))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The argv that starts `argv` under the profile written to the run directory.
    static func wrap(_ argv: [String], launcher: String, copy: URL, runDirectory: URL, harness: String, home: String) throws -> [String] {
        let file = runDirectory.appendingPathComponent("confine.sb")
        let text = profile(copy: copy.path, runDirectory: runDirectory.path, executable: argv[0], harness: harness, home: home)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return [launcher, "-f", file.path] + argv
    }
}
