import CryptoKit
import Foundation

/// The frozen packet of a sitting: one commit, and optionally the tracked working-tree changes at wake time.
struct Snapshot: Equatable {
    let id: String
    let commit: String
    let patch: Data?
    let patchHash: String
    let repo: String?

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Git options that stop a repository's own configuration from running programs while its changes are read:
    /// the file system monitor and every configured clean, smudge or process filter.
    private static func inert(_ repo: String) -> [String] {
        let keys = (RepoCopy.output(["-C", repo, "config", "--name-only", "--get-regexp", #"^filter\..*\.(clean|smudge|process)$"#]) ?? "")
            .split(separator: "\n").map(String.init)
        return (["core.fsmonitor=false"] + keys.map { $0 + "=" }).flatMap { ["-c", $0] }
    }

    /// Resolves `HEAD` once and, with `uncommitted`, captures `git diff HEAD`. Without a repo the commit is `none`.
    static func take(repo: String?, uncommitted: Bool, question: String) throws -> Snapshot {
        var commit = "none"
        var patch: Data?
        if let repo {
            guard let head = RepoCopy.output(["-C", repo, "rev-parse", "--verify", "HEAD^{commit}"]), !head.isEmpty else {
                throw Refusal(exit: 4, message: "failed: repo \(repo) has no commit to copy")
            }
            commit = head
            if uncommitted {
                guard let diff = RepoCopy.data(["-C", repo] + inert(repo) + ["diff", "--binary", "--no-ext-diff", "--no-textconv", head]) else {
                    throw Refusal(exit: 4, message: "failed: repo \(repo) changes cannot be captured")
                }
                if !diff.isEmpty { patch = diff }
            }
        }
        let patchHash = sha256(patch ?? Data())
        let digest = sha256(Data((commit + "\n" + patchHash + "\n" + sha256(Data(question.utf8))).utf8))
        return Snapshot(id: "sn_" + digest.prefix(16), commit: commit, patch: patch, patchHash: patchHash, repo: repo)
    }
}
