import Foundation
import Testing

@Suite(.serialized) struct U6dPacketAcceptanceTests {
    @Test func headCopyContainsCommittedFilesWithoutGitOrDirtyChangesAndIsRemovedOnSuccess() throws {
        let r = try U6dRig(); try r.repository()
        _ = try r.base.answered(r.ask())
        let tree = try r.observation(".tree")
        #expect(tree.contains("./README\n")); #expect(tree.contains("./src/main.swift\n"))
        #expect(!tree.contains(".git/"))
        #expect(try r.observation(".readme") == "COMMITTED_MARKER")
        try r.removedCopy()
    }
    @Test func hostedCopyRedactsNamesIgnorePatternsAndContentWhileLocalCopyKeepsEverything() throws {
        let secretNames = [".env", ".env.local", "deploy.pem", "server.key", "id_ed25519", "credentials.json",
                           "my-secret.txt", "api-token.txt", ".ssh/config", ".aws/credentials", "hidden.txt", "private-dir/item"]
        var files = Dictionary(uniqueKeysWithValues: secretNames.enumerated().map { ($0.element, "WITHHELD_\($0.offset)_MARKER") })
        files["aws.txt"] = "AKIA1234567890ABCDEF"
        files["github.txt"] = "ghp_abcdefghijklmnopqrstuvwxyz123456"
        files["private.txt"] = "-----BEGIN RSA PRIVATE KEY-----\nfixture\n-----END RSA PRIVATE KEY-----"
        files["provider.txt"] = "sk-abcdefghijklmnopqrstuvwxyz123456"
        files["slack.txt"] = "xoxb-fixturevalue"
        files["pat.txt"] = "github_pat_fixturevalue"
        files[".agencilignore"] = "# fixture\n\nhidden.txt\nprivate-dir/\n"
        files["README"] = "COMMITTED_MARKER"; files["src/main.swift"] = "print(1)"
        for hosted in [true, false] {
            let r = try U6dRig(); try r.repository(files)
            try r.configure([u6aSeat(extra: ["hosted": hosted])])
            _ = try r.base.answered(r.ask())
            let tree = Set(try r.observation(".tree").split(separator: "\n").map(String.init))
            // The spec's patterns do not match .agencilignore itself; retain it.
            let expected = hosted ? ["README", "src/main.swift", ".agencilignore"] : Array(files.keys)
            #expect(tree == Set(expected.map { "./" + $0 }))
            let prompt = try r.observation(".prompt")
            if hosted {
                for (name, content) in files where !expected.contains(name) { #expect(!prompt.contains(content)) }
            }
        }
    }
    @Test func hostedAttachmentsWithholdMatchedPathAndContentAndEmbedUnmatchedText() throws {
        let r = try U6dRig()
        let secret = r.home.url.appendingPathComponent(".env")
        let plain = r.home.url.appendingPathComponent("notes.txt")
        try r.put(secret, "ATTACHMENT_SECRET_MARKER"); try r.put(plain, "ATTACHMENT_PUBLIC_MARKER")
        _ = try r.base.answered(r.ask(repo: false, extra: ["files": [secret.path, plain.path]]))
        let prompt = try r.base.contents(".prompt")
        #expect(prompt.contains("[1 file(s) withheld by the redaction rules]"))
        #expect(!prompt.contains(secret.path)); #expect(!prompt.contains("ATTACHMENT_SECRET_MARKER"))
        #expect(prompt.contains("ATTACHMENT_PUBLIC_MARKER"))
    }
    @Test func repoAndOpenCodeBriefsUseRelativeFilesWhileUnconfinedCodexEmbedsText() throws {
        for scenario in ["repo", "opencode", "codex"] {
            let r = try U6dRig()
            if scenario == "repo" { try r.repository() }
            try r.configure([u6aSeat("primary", scenario == "opencode" ? "opencode" : "codex")])
            let attachment = r.home.url.appendingPathComponent("name")
            try r.put(attachment, "BRIEF_TEXT_MARKER")
            // Exercise the real CLI parser as well as broker request fields.
            var args = ["ask", "primary", "brief question", "--file", attachment.path]
            if scenario == "repo" { args += ["--repo", r.repo.path] }
            let (code, _, _) = try r.home.cli(args)
            #expect(code == 0)
            if scenario == "codex" {
                #expect(try r.base.contents(".prompt").contains("BRIEF_TEXT_MARKER"))
            } else {
                let prompt = try r.observation(".prompt")
                #expect(prompt.contains("FILE .agencil/briefs/1-name: attached"))
                #expect(!prompt.contains("BRIEF_TEXT_MARKER"))
                #expect(try r.observation(".briefs") == "BRIEF_TEXT_MARKER")
                #expect(try r.observation(".tree").contains("./.agencil/briefs/1-name"))
                if scenario == "opencode" {
                    let cwd = try r.observation(".cwd").trimmingCharacters(in: .whitespacesAndNewlines)
                    #expect(cwd.hasPrefix(r.home.url.path + "/runs/")); #expect(!cwd.hasSuffix("/copy"))
                }
            }
        }
    }
    @Test func confinementDeniesHomeSiblingSymlinkGitAndRealRepoButAllowsCopyConfigAndAnswer() throws {
        let r = try U6dRig(mode: "probe"); try r.repository(symlink: true)
        // ../../ from runs/<thread>-1/copy is runs/, outside the run allow-list.
        try r.put(r.home.url.appendingPathComponent("runs/outside"), "SIBLING_DENIED_MARKER")
        _ = try r.base.answered(r.ask())
        let probes = try r.observation(".probes")
        #expect(probes.split(separator: "\n").count == 5)
        #expect(probes.split(separator: "\n").allSatisfy { $0.hasPrefix("DENIED ") })
        #expect(try r.observation(".config") == "HARNESS_ALLOWED_MARKER")
        #expect(try r.observation(".readme") == "COMMITTED_MARKER")
        let files = FileManager.default.enumerator(at: r.home.url.appendingPathComponent("runs"), includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.lastPathComponent.hasPrefix("u6d"), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for marker in ["HOME_DENIED_MARKER", "SIBLING_DENIED_MARKER", "UNCOMMITTED_MARKER"] {
                #expect(!text.contains(marker))
            }
        }
        let invocation = try r.base.contents(".sandbox")
        #expect(invocation.contains("-p\n") || invocation.contains("-f\n"))
        #expect(invocation.contains(r.base.bin.appendingPathComponent("codex").path))
        try r.removedCopy()
    }
    @Test func noRepoKeepsOriginalCodexArgvWithoutSandboxWrapping() throws {
        let r = try U6dRig()
        _ = try r.base.answered(r.ask(repo: false))
        let args = try r.base.contents(".argv").split(separator: "\n").map(String.init)
        #expect(Array(args.prefix(10)) == ["exec", "--ignore-user-config", "--disable", "hooks", "-s", "read-only", "--skip-git-repo-check", "-o", args.count > 8 ? args[8] : "", "-m"])
        #expect(try r.base.contents(".argc") == "12\n")
        #expect(try r.base.contents(".prompt") == "QUESTION:\ntest question")
        #expect(!FileManager.default.fileExists(atPath: r.base.record.path + ".sandbox"))
    }
    @Test func missingSandboxFailsClosedBeforeStubRuns() throws {
        let r = try U6dRig(sandbox: "/nonexistent"); try r.repository()
        r.base.refused(try r.ask(), "failed: confinement unavailable")
        r.base.noAnswerSpawned()
        #expect(!FileManager.default.fileExists(atPath: r.base.record.path + ".argv"))
        let files = FileManager.default.enumerator(atPath: r.home.url.appendingPathComponent("runs").path)
        #expect(!(files?.allObjects as? [String] ?? []).contains { $0.hasSuffix("u6d.argv") })
    }
    @Test func failedSeatExit17AlsoRemovesCopy() throws {
        let r = try U6dRig(mode: "fail"); try r.repository()
        let reply = try r.ask()
        let data = try r.base.data(reply)
        #expect(data["state"] as? String == "failed")
        #expect((data["reason"] as? String)?.contains("17") == true)
        let thread = try #require(data["thread"] as? String)
        let (code, _, _) = try r.home.cli(["result", thread])
        #expect(code == 4)
        try r.removedCopy()
    }
}
