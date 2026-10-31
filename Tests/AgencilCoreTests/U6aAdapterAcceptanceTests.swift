import Foundation
import Testing

@Suite(.serialized)
struct U6aAdapterAcceptanceTests {
    @Test func codexReceivesExactHardenedArgvAndClosedStdin() throws { try adapter("codex") }
    @Test func claudeReceivesExactHardenedArgvAndClosedStdin() throws { try adapter("claude") }
    @Test func opencodeUnknownSigninIsUsableWithExactArgvAndPerRunPolicy() throws { try adapter("opencode") }
    @Test func hermesUnknownSigninIsUsableWithExactArgvAndClosedStdin() throws { try adapter("hermes") }

    private func adapter(_ kind: String) throws {
        let rig = try U6aRig([kind])
        try rig.config(seats: [u6aSeat("primary", kind)])
        let file = rig.home.url.appendingPathComponent("evidence.txt")
        try "untrusted file text".write(to: file, atomically: true, encoding: .utf8)
        _ = try rig.answered(rig.ask(question: "literal $(echo nope); 'quoted'", extra: ["files": [file.path]]))
        #expect(try rig.contents(".exe") == rig.bin.appendingPathComponent(kind).path + "\n")
        let recorded = try rig.contents()
        // Prompt contains newlines: reconstruct ONE prompt argument from the known suffix/prefix.
        let promptStart: String
        let prefix: [String]
        let suffix: [String]
        switch kind {
        case "codex":
            let lines = recorded.components(separatedBy: "\n")
            #expect(Array(lines.prefix(8)) == ["exec", "--ignore-user-config", "--disable", "hooks", "-s", "read-only", "--skip-git-repo-check", "-o"])
            let answer = try #require(lines.count > 8 ? lines[8] : nil)
            #expect(answer.hasPrefix(rig.home.url.appendingPathComponent("runs").path + "/"))
            prefix = ["exec", "--ignore-user-config", "--disable", "hooks", "-s", "read-only", "--skip-git-repo-check", "-o", answer, "-m", "test-model"]
            suffix = []
        case "claude":
            prefix = ["-p"]
            suffix = ["--model", "test-model", "--setting-sources", "user", "--strict-mcp-config", "--permission-mode", "plan"]
        case "opencode": prefix = ["run", "--model", "test-model"]; suffix = []
        default: prefix = ["chat", "-q"]; suffix = ["--model", "test-model"]
        }
        #expect(try rig.contents(".argc") == String(prefix.count + suffix.count + 1) + "\n")
        let leading = prefix.joined(separator: "\n") + "\n"
        let trailing = suffix.isEmpty ? "\n" : "\n" + suffix.joined(separator: "\n") + "\n"
        #expect(recorded.hasPrefix(leading))
        #expect(recorded.hasSuffix(trailing))
        promptStart = String(recorded.dropFirst(leading.count).dropLast(trailing.count))
        #expect(promptStart.contains("QUESTION:\nliteral $(echo nope); 'quoted'"))
        if kind == "opencode" {
            #expect(promptStart.contains("FILE .agencil/briefs/1-evidence.txt: attached"))
            #expect(!promptStart.contains("untrusted file text"))
            #expect(!promptStart.contains(file.path))
        } else {
            #expect(promptStart.contains("FILE \(file.path):\nuntrusted file text"))
        }
        #expect(recorded == leading + promptStart + trailing)
        #expect(try rig.contents(".stdin") == "empty-closed\n")
        if kind == "opencode" {
            let cwd = try rig.contents(".cwd").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(cwd.hasPrefix(rig.home.url.appendingPathComponent("runs").path + "/"))
            let brief = URL(fileURLWithPath: cwd).appendingPathComponent(".agencil/briefs/1-evidence.txt")
            #expect(try String(contentsOf: brief, encoding: .utf8) == "untrusted file text")
            #expect(try rig.contents(".config") == cwd + "/opencode.json\n")
            let policy = try brokerJSON(Data(rig.contents(".policy").utf8))
            #expect(policy.count == 1)
            #expect(policy["permission"] as? [String: String] == ["edit": "deny", "bash": "deny", "webfetch": "deny", "external_directory": "deny"])
        }
    }

    @Test func ollamaPostsModelMessagesStreamAndTokenCapAndUsesContentAsAnswer() throws {
        let server = try U6aHTTP()
        defer { server.stop() }
        let rig = try U6aRig([])
        try rig.config(seats: [u6aSeat("primary", "ollama", extra: ["endpoint": server.endpoint])])
        _ = try rig.answered(rig.ask(question: "ollama question"))
        let body = try #require(server.requests().first)
        #expect(body["model"] as? String == "test-model")
        #expect(body["stream"] as? Bool == false)
        #expect((body["options"] as? [String: Int])?["num_predict"] == 37)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.contains { ($0["content"] as? String)?.contains("QUESTION:\nollama question") == true })
        #expect(messages.allSatisfy { $0["role"] is String && $0["content"] is String })
        rig.noAnswerSpawned()
    }

    @Test func ollamaDownEndpointAndMissingModelFailAndEndpointFallbackApplies() throws {
        let server = try U6aHTTP(models: [])
        defer { server.stop() }
        let endpoint = server.endpoint
        let rig = try U6aRig(["hermes"])
        try rig.config(seats: [u6aSeat("primary", "ollama", extra: ["endpoint": endpoint])])
        rig.refused(try rig.ask(), "failed: model test-model not loaded at \(endpoint)")
        server.stop()
        rig.refused(try rig.ask(), "failed: \(endpoint) down")
        try rig.config(seats: [u6aSeat("primary", "ollama", extra: ["endpoint": endpoint]), u6aSeat("backup", "hermes")],
                       routes: [u6aRoute(fallbacks: ["backup"])])
        let data = try rig.answered(rig.ask(), seat: "backup")
        #expect(data["substituted"] as? String == "answered by backup, fallback for primary: \(endpoint) down")
    }

    @Test func unsupportedHarnessesFailWithNoAdapterReason() throws {
        let rig = try U6aRig(["gemini", "aider", "goose"])
        for kind in ["gemini", "aider", "goose"] {
            try rig.config(seats: [u6aSeat("primary", kind)])
            rig.refused(try rig.ask(), "failed: \(kind) has no adapter")
            rig.noAnswerSpawned()
        }
    }

    @Test func oversizedFileIsCutWithVisibleMarkerAndUnreadableFileExits64BeforeSpawn() throws {
        let rig = try U6aRig()
        let missing = rig.home.url.appendingPathComponent("missing")
        let (code, _, _) = try rig.home.cli(["ask", "primary", "question", "--file", missing.path])
        #expect(code == 64)
        rig.noAnswerSpawned()
        let file = rig.home.url.appendingPathComponent("large.txt")
        try (String(repeating: "x", count: 65_536) + "END_MUST_NOT_ARRIVE").write(to: file, atomically: true, encoding: .utf8)
        let (answerCode, _, _) = try rig.home.cli(["ask", "primary", "question", "--file", file.path, "--wait", "10"])
        #expect(answerCode == 0)
        let prompt = try rig.contents()
        #expect(prompt.contains("QUESTION:\nquestion"))
        #expect(prompt.contains("FILE \(file.path):"))
        #expect(!prompt.contains("END_MUST_NOT_ARRIVE"))
        #expect(prompt.lowercased().contains("truncat") || prompt.lowercased().contains("cut"))
    }
}
