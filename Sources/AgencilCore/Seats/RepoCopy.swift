import Foundation

/// The packet a seat works on: a copy of a repo's committed files, and the attachments written beside it.
enum RepoCopy {
    private static let git = URL(fileURLWithPath: "/usr/bin/git")
    private static let exportSeconds = 300.0
    /// The repo's text is untrusted: no user or system git configuration is read on its behalf.
    private static let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                      "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"]

    /// Ends helpers that are still running: asked politely first, then for good.
    static func stop(_ processes: [Process]) {
        for process in processes where process.isRunning { process.terminate() }
        let grace = Date().addingTimeInterval(2)
        while processes.contains(where: \.isRunning), Date() < grace { usleep(10_000) }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for process in processes { process.waitUntilExit() }
    }

    static func data(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { stop([process]) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// The exit status of a git call, or nil when it could not run or was ended by the deadline.
    static func status(_ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { stop([process]) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }

    static func output(_ arguments: [String]) -> String? {
        data(arguments).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// An absolute path that is the top of a git work tree.
    static func isRepository(_ path: String) -> Bool {
        guard path.hasPrefix("/"), let top = output(["-C", path, "rev-parse", "--show-toplevel"]) else { return false }
        return URL(fileURLWithPath: top).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Exports `commit` into `copy`: no `.git`; the only uncommitted change is `patch`, applied on top.
    static func export(repo: String, commit: String = "HEAD", patch: Data? = nil, to copy: URL) throws {
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = Process(), extract = Process(), pipe = Pipe()
        archive.executableURL = git
        archive.arguments = ["-C", repo, "archive", "--format=tar", commit]
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extract.arguments = ["-x", "-f", "-", "-C", copy.path]
        for process in [archive, extract] { process.environment = environment; process.standardError = FileHandle.nullDevice }
        archive.standardOutput = pipe
        extract.standardInput = pipe
        try archive.run()
        try extract.run()
        // The parent's ends of the pipe stay closed, or the extractor never sees the end of the archive.
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
        // A copy that does not finish in time is an ask that fails, never one that holds its place for ever.
        let deadline = Date().addingTimeInterval(exportSeconds)
        while archive.isRunning || extract.isRunning {
            if Date() >= deadline {
                stop([archive, extract])
                throw Refusal(exit: 4, message: "failed: copying repo \(repo) took too long")
            }
            usleep(10_000)
        }
        guard archive.terminationStatus == 0, extract.terminationStatus == 0 else {
            throw Refusal(exit: 4, message: "failed: repo \(repo) has no commit to copy")
        }
        if let patch { try apply(patch, to: copy) }
    }

    /// Applies the captured working-tree changes to the copy. Repository discovery stops above the copy, so the patch
    /// is applied to these files and never to a repository that happens to contain the run directory.
    private static func apply(_ patch: Data, to copy: URL) throws {
        // The patch holds changed files unredacted, so it never sits in the run directory a seat may read.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agencil-patch-" + UUID().uuidString)
        try patch.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = git
        process.arguments = ["apply", "--whitespace=nowarn", file.path]
        process.currentDirectoryURL = copy
        process.environment = environment.merging(["GIT_CEILING_DIRECTORIES": copy.deletingLastPathComponent().path]) { _, mine in mine }
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning {
            if Date() >= deadline { stop([process]); throw Refusal(exit: 4, message: "failed: applying the captured changes took too long") }
            usleep(10_000)
        }
        guard process.terminationStatus == 0 else { throw Refusal(exit: 4, message: "failed: the captured changes do not apply to the commit") }
    }

    /// Writes each attachment as `<directory>/.agencil/briefs/<n>-<basename>`; returns the names relative to `directory`.
    static func writeBriefs(_ files: [(path: String, text: String)], into directory: URL) throws -> [String] {
        // The repo may have committed `.agencil` as a link: it is replaced, never followed, so nothing lands outside.
        let root = directory.appendingPathComponent(".agencil")
        if (try? FileManager.default.attributesOfItem(atPath: root.path)) != nil { try FileManager.default.removeItem(at: root) }
        let briefs = root.appendingPathComponent("briefs")
        try FileManager.default.createDirectory(at: briefs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try files.enumerated().map { index, file in
            let base = (file.path as NSString).lastPathComponent
            let name = "\(index + 1)-\(base.isEmpty ? "file" : base)"
            try file.text.write(to: briefs.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return ".agencil/briefs/" + name
        }
    }
}
