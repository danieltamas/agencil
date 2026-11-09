import Foundation

/// A confined harness that must write its own home gets a fresh one inside the run directory (docs/U34-SPEC.md):
/// Codex refuses to start on a read-only ~/.codex, and a writable real one would let a steered seat plant config,
/// hooks or skills that run unconfined later. Only the login is copied in, and nothing the seat writes comes back:
/// the broker cannot prove that tokens a seat wrote belong to the owner's account.
enum SeatHome {
    private struct Layout {
        let variable: String
        let directory: String
        let login: String
    }

    private static let layouts: [String: Layout] = ["codex": Layout(variable: "CODEX_HOME", directory: ".codex", login: "auth.json")]

    static func prepare(harness: String, runDirectory: URL, home: String) throws -> [String: String]? {
        guard let layout = layouts[harness] else { return nil }
        let seatHome = runDirectory.appendingPathComponent("home").appendingPathComponent(layout.directory)
        let manager = FileManager.default
        try manager.createDirectory(at: seatHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: seatHome.deletingLastPathComponent().path)
        if let login = ownerLogin(home + "/" + layout.directory + "/" + layout.login) {
            guard manager.createFile(atPath: seatHome.appendingPathComponent(layout.login).path, contents: login,
                                     attributes: [.posixPermissions: 0o600]) else {
                throw Refusal(exit: 70, message: "failed: could not prepare the seat's home")
            }
        }
        return [layout.variable: seatHome.path]
    }

    static func remove(runDirectory: URL) {
        try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("home"))
    }

    /// The owner's login when it is a regular file; a link, a missing file or anything else copies nothing, and the
    /// seat then runs logged out. Non-blocking, so a FIFO in its place cannot hang the ask.
    private static func ownerLogin(_ path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}
