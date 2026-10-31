import CryptoKit
import Foundation
import Testing

@Suite(.serialized) struct U7aSnapshotAcceptanceTests {
    private func git(_ r: U7aRig, _ args: [String]) throws -> String {
        let p = try BrokerProcess(["-C", r.packet.repo.path] + args, home: r.home.url,
                                  executable: URL(fileURLWithPath: "/usr/bin/git"))
        let (code, out, _) = try p.finish(15); #expect(code == 0); return out
    }
    private func cleanRepo(_ r: U7aRig) throws {
        try r.packet.repository(["README": "FROZEN_MARKER", "src/main.swift": "print(1)", ".env": "SECRET_MARKER"])
        _ = try git(r, ["checkout", "--", "README"])
        try r.configure(u7aCouncil(["seats": ["a", "b"]]))
    }
    private func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    @Test func sameFrozenSnapshotSurvivesLiveCommitAndCopiesAreRemoved() throws {
        let r = try U7aRig(); try cleanRepo(r)
        let commit = try git(r, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        for s in ["a", "b"] {
            try r.put(s + ".blind.hold")
            try r.reply(s, u7aAnswer(claims: [u7aClaim(evidence: "FROZEN_CLAIM_" + s)]))
        }
        try r.put("frozen.brief", "change_kind: design\nquestion: frozen question\nauthor_vendor: google\n")
        let pending = try r.cli(["wake", "panel", "--brief", r.control.appendingPathComponent("frozen.brief").path,
                                "--repo", r.packet.repo.path, "--wait", "0"], exit: 2)
        #expect(pending["state"] as? String == "pending")
        let id = try #require(pending["sitting"] as? String)
        try brokerPoll(15) { r.observations(nil, "blind").count == 2 }
        try r.packet.put(r.packet.repo.appendingPathComponent("README"), "LIVE_NEW_MARKER")
        try r.packet.put(r.packet.repo.appendingPathComponent("new.txt"), "LIVE_NEW_MARKER")
        _ = try git(r, ["add", "."])
        _ = try git(r, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "next"])
        try r.put("release")
        let v = try r.verdict(r.cli(["result", id, "--wait", "15"], exit: 0))
        let snapshot = try #require(v["snapshot"] as? String)
        #expect(snapshot == "sn_" + hash(commit + "\n" + hash("") + "\n" + hash("frozen question")).prefix(16))
        for s in ["a", "b"] {
            #expect(try r.prompt(s).contains("SNAPSHOT: " + snapshot))
            #expect(try r.text(#require(r.observations(s, suffix: "readme").first)) == "FROZEN_MARKER")
            let tree = try r.text(#require(r.observations(s, suffix: "tree").first))
            #expect(!tree.contains("new.txt")); #expect(!tree.contains(".env"))
            let cwd = try r.text(#require(r.observations(s, suffix: "cwd").first)).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(cwd.hasPrefix(r.home.url.path + "/runs/")); #expect(cwd.hasSuffix("/copy"))
            try brokerPoll(15) { !FileManager.default.fileExists(atPath: cwd) }
        }
        #expect(try r.sql("SELECT count(*) FROM runs WHERE kind='sitting' AND snapshot_id='\(snapshot)';") == "1\n")
        #expect(try r.sql("SELECT count(*) FROM claims c JOIN runs r ON c.run_id=r.id WHERE r.snapshot_id='\(snapshot)';") == "2\n")
        #expect(try r.sql("SELECT count(*) FROM verdicts WHERE snapshot_id='\(snapshot)';") == "1\n")
    }
    @Test func uncommittedTrackedPatchIsInEveryCopyButUntrackedFileIsAbsent() throws {
        let r = try U7aRig(); try cleanRepo(r)
        try r.packet.put(r.packet.repo.appendingPathComponent("README"), "PATCH_MARKER")
        try r.packet.put(r.packet.repo.appendingPathComponent("untracked.txt"), "UNTRACKED_MARKER")
        _ = try r.decided("PASS", extra: ["--repo", r.packet.repo.path],
            brief: "change_kind: design\nquestion: patch question\nauthor_vendor: google\nuncommitted: true\n")
        for s in ["a", "b"] {
            #expect(try r.text(#require(r.observations(s, suffix: "readme").first)) == "PATCH_MARKER")
            #expect(try !r.text(#require(r.observations(s, suffix: "tree").first)).contains("untracked.txt"))
        }
    }
    @Test func snapshotIDIsStableForSameInputsAndChangesForQuestionPatchOrCommit() throws {
        let r = try U7aRig(); try cleanRepo(r)
        func snapshot(_ question: String = "same", patched: Bool = false) throws -> String {
            let v = try r.decided("PASS", extra: ["--repo", r.packet.repo.path],
                brief: "change_kind: design\nquestion: \(question)\nauthor_vendor: google\nuncommitted: \(patched)\n")
            return try #require(v["snapshot"] as? String)
        }
        let first = try snapshot(); #expect(try snapshot() == first)
        #expect(try snapshot("different") != first)
        try r.packet.put(r.packet.repo.appendingPathComponent("README"), "PATCH_MARKER")
        let patch = try snapshot(patched: true); #expect(patch != first)
        #expect(try snapshot(patched: true) == patch)
        _ = try git(r, ["add", "."])
        _ = try git(r, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "patch"])
        let committed = try snapshot(); #expect(committed != first); #expect(committed != patch)
    }
    @Test func hostedSnapshotRedactsSecretNamedFile() throws {
        let r = try U7aRig(); try cleanRepo(r)
        _ = try r.decided("PASS", extra: ["--repo", r.packet.repo.path])
        for s in ["a", "b"] {
            let tree = try r.text(#require(r.observations(s, suffix: "tree").first))
            #expect(tree.contains("README")); #expect(!tree.contains(".env"))
            #expect(try !r.prompt(s).contains("SECRET_MARKER"))
        }
    }
}
