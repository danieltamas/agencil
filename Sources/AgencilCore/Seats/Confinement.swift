import Foundation

/// Runs a seat that works on a repo copy inside an OS sandbox (docs/U6-SPEC.md "Confinement"): everything is denied
/// except what the seat needs, so a harness that wanders reads nothing of the owner's home, secrets or other repos.
/// The profile is written by the broker from paths the broker chose; nothing in it comes from the repo.
enum Confinement {
    static let systemExecutable = "/usr/bin/sandbox-exec"
    /// "/etc" is a link to "/private/etc": the link itself is read before it is followed, so both spellings are listed.
    private static let systemReadable = ["/usr", "/bin", "/sbin", "/System", "/Library", "/etc", "/private/etc", "/private/var/db", "/dev",
                                         "/private/var/select", "/Applications/Xcode.app", "/opt/homebrew", "/usr/local"]
    /// Codex is absent: it gets a home of its own in the run directory (SeatHome), never the owner's ~/.codex.
    private static let harnessConfig: [String: [String]] = [
        "claude": [".claude", ".claude.json"], "opencode": [".config/opencode", ".local/share/opencode"], "hermes": [".hermes"],
    ]
    /// The system resolver's socket, reached as /var/run/mDNSResponder through the /var link: without these no host name
    /// resolves inside the sandbox, though network itself is allowed (docs/U34-SPEC.md).
    private static let resolverLiterals = ["/var", "/private/var/run", "/private/var/run/mDNSResponder"]

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

    /// What `argv[0]` needs read: its own directory and, when it is a link, where it really lives. An npm install's
    /// `bin/codex` points into `lib/node_modules/@openai/codex`, whose script loads files from the whole package, so the
    /// package root is granted, and nothing above it.
    static func executableReads(_ executable: String) -> [String] {
        let linked = real((executable as NSString).deletingLastPathComponent)
        guard let resolved = realpath(executable, nil) else { return [linked] }
        let target = String(cString: resolved)
        free(resolved)
        var reads = [linked, (target as NSString).deletingLastPathComponent]
        if let root = packageRoot(of: target) { reads.append(root) }
        return Array(Set(reads)).sorted()
    }

    /// `/a/node_modules/@scope/name/bin/x.js` -> `/a/node_modules/@scope/name`; `/a/node_modules/name/x.js` -> `/a/node_modules/name`.
    private static func packageRoot(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let modules = parts.lastIndex(of: "node_modules") else { return nil }
        let nameParts = parts.count > modules + 1 && parts[modules + 1].hasPrefix("@") ? 2 : 1
        // The package directory must be a directory above the file, never the file itself.
        guard parts.count > modules + nameParts + 1, !parts[(modules + 1)...(modules + nameParts)].contains("") else { return nil }
        return parts[...(modules + nameParts)].joined(separator: "/")
    }

    /// A directory too wide to hand a seat for the sake of its executable: the home or above it, the Agencil home or
    /// above it, a whole `node_modules`, or a credential folder (docs/U34-SPEC.md item 2).
    private static func tooBroad(_ directory: String, home: String, brokerHome: String) -> Bool {
        func within(_ inner: String, _ outer: String) -> Bool { inner == outer || inner.hasPrefix(outer + "/") }
        // Compared in the kernel's spelling: a credential folder that is itself a link is judged by where it leads.
        let credentials = [".ssh", ".aws", ".gnupg", ".codex", ".agencil"].map { real(home + "/" + $0) }
        return directory == "/" || (directory as NSString).lastPathComponent == "node_modules"
            || ([real(home), real(brokerHome)] + credentials).contains { within($0, directory) }
            || credentials.contains { within(directory, $0) }
    }

    /// `egressPort` set: the seat's commands inherit this profile (docs/U38-SPEC.md), so its only network is the broker's
    /// proxy on that loopback port. Nil: the harness keeps its commands off the network itself.
    static func profile(copy: String, runDirectory: String, executable: String, harness: String, home: String, brokerHome: String,
                        egressPort: Int? = nil) -> String {
        let network = egressPort.map { "(allow network-outbound (remote tcp \"localhost:\($0)\"))" } ?? "(allow network*)"
        let named = [copy, runDirectory] + (harnessConfig[harness] ?? []).map { home + "/" + $0 }
        let copy = real(copy), run = real(runDirectory)
        let executableDirectories = executableReads(executable)
        // A `node_modules` that is itself a link is judged by its own name, since its resolved spelling hides it.
        let linkedDirectory = (executable as NSString).deletingLastPathComponent
        let linkedModules = (linkedDirectory as NSString).lastPathComponent == "node_modules" ? real(linkedDirectory) : nil
        let granted = executableDirectories.filter { !tooBroad($0, home: home, brokerHome: brokerHome) && $0 != linkedModules }
        // A refused directory still leaves the executable itself readable, or the seat could not start at all.
        let executableFiles = granted.count == executableDirectories.count ? [] : Array(Set([executable, real(executable)])).sorted()
        let reads = Array(Set(named.map(real) + granted)).sorted() + systemReadable
        // The walk is allowed along both spellings of a path: a link such as /tmp is read before it is followed.
        let walk = Set((reads + named + executableFiles + [(executable as NSString).deletingLastPathComponent]).flatMap(ancestors(of:))).sorted()
        let files = executableFiles.map { "(literal \(quoted($0)))" }.joined()
        let resolver: String = "(allow file-read* " + resolverLiterals.map { "(literal \(quoted($0)))" }.joined(separator: " ") + ")"
        let lines: [String] = [
            "(version 1)", "(deny default)",
            "(allow process-exec) (allow process-fork) (allow signal (target self)) (allow sysctl-read)",
            "(allow mach-lookup) (allow ipc-posix-shm) \(network)",
            // A seat reaches the model's API, never the broker: the last matching rule wins, so this denies the broker's
            // socket after network is allowed. Both spellings, because the kernel matches the resolved path.
            "(deny network* (remote unix-socket (subpath \(quoted(brokerHome)))))",
            "(deny network* (remote unix-socket (subpath \(quoted(real(brokerHome))))))",
            "(allow file-read-metadata " + walk.map { "(literal \(quoted($0)))" }.joined(separator: " ") + ")",
            "(allow file-read* (literal \"/\") " + files + reads.map { "(subpath \(quoted($0)))" }.joined(separator: " ") + ")",
            resolver,
            "(allow file-write* (subpath \(quoted(run))) (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (literal \"/dev/tty\")"
                + " (regex #\"^/dev/(fd|ttys?)[0-9]*$\"))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The argv that starts `argv` under the profile written to the run directory.
    static func wrap(_ argv: [String], launcher: String, copy: URL, runDirectory: URL, harness: String, home: String, brokerHome: String,
                     egressPort: Int? = nil) throws -> [String] {
        let file = runDirectory.appendingPathComponent("confine.sb")
        let text = profile(copy: copy.path, runDirectory: runDirectory.path, executable: argv[0], harness: harness, home: home, brokerHome: brokerHome,
                           egressPort: egressPort)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return [launcher, "-f", file.path] + argv
    }
}
