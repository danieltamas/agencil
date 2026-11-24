import Foundation

/// A confined harness that must write its own home gets a fresh one inside the run directory (docs/U34-SPEC.md):
/// Codex refuses to start on a read-only ~/.codex, and a writable real one would let a steered seat plant config,
/// hooks or skills that run unconfined later. Only the login is copied in, and nothing the seat writes comes back:
/// the broker cannot prove that tokens a seat wrote belong to the owner's account.
enum SeatHome {
    /// One folder the harness writes, named to it by `variable`. `seeds` are owner files copied in, relative to both
    /// `source` (under the owner's home) and the fresh folder.
    private struct Folder {
        let variable: String
        let directory: String
        let source: String
        let seeds: [String]
    }

    /// OpenCode keeps data, state and cache in three XDG folders and crashes when one is not writable; its config stays
    /// the owner's, read-only (Confinement). The model catalog is seeded so the seat resolves the same model names.
    private static let layouts: [String: [Folder]] = [
        "codex": [Folder(variable: "CODEX_HOME", directory: ".codex", source: ".codex", seeds: ["auth.json"])],
        "opencode": [
            Folder(variable: "XDG_DATA_HOME", directory: "data", source: ".local/share", seeds: ["opencode/auth.json"]),
            Folder(variable: "XDG_STATE_HOME", directory: "state", source: ".local/state", seeds: []),
            Folder(variable: "XDG_CACHE_HOME", directory: "cache", source: ".cache", seeds: ["opencode/models.json"]),
        ],
    ]

    /// Larger than any login or model catalog: a seed over it is not copied. A seed that is a link, sits under a linked
    /// folder, is missing or is not a regular file copies nothing either, and the seat then runs without it.
    private static let seedLimit = 32 << 20

    static func prepare(harness: String, runDirectory: URL, home: String) throws -> [String: String]? {
        guard let folders = layouts[harness] else { return nil }
        let manager = FileManager.default
        let root = runDirectory.appendingPathComponent("home")
        var environment: [String: String] = [:]
        for folder in folders {
            let seatFolder = root.appendingPathComponent(folder.directory)
            try manager.createDirectory(at: seatFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            for seed in folder.seeds {
                guard let contents = SafeRead.ownerFile(home: home, relative: folder.source + "/" + seed, limit: seedLimit) else { continue }
                let target = seatFolder.appendingPathComponent(seed)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                guard manager.createFile(atPath: target.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
                    throw Refusal(exit: 70, message: "failed: could not prepare the seat's home")
                }
            }
            environment[folder.variable] = seatFolder.path
        }
        return environment
    }

    static func remove(runDirectory: URL) {
        try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("home"))
    }
}
