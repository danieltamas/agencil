import Darwin
import Foundation
import Testing

// Expectations come from docs/U32-SPEC.md, not the broker implementation.
@Suite(.serialized)
struct U32DoorsAcceptanceTests {
    private static let gated = ["ask", "wake", "result", "status", "stop", "list_targets"]
    private static let ownerOnly = ["panel", "detail", "findings", "costs", "data", "launch",
        "adjudicate", "prune", "leaderboard", "budgets", "proposals", "unknown"]
    private static let doors = ["agent.sock", "agencil.sock"]

    private func configure(_ r: U25Rig, access: String? = "on") throws {
        try r.base.config(seats: u25Seats(), routes: [
            u6aRoute("a", callers: ["owner", "a", "b", "maya"]),
            u6aRoute("panel", callers: ["owner", "a", "b"])], agentAccess: nil,
            raw: ["councils": try u6aText([u7aCouncil()])]
                .merging(access.map { ["agent_access": $0] } ?? [:]) { _, b in b })
    }

    private func fields(_ op: String) -> [String: Any] {
        switch op {
        case "ask": return ["target": "a", "question": "inspect harbor", "wait_seconds": 10]
        case "wake": return ["council": "panel", "question": "inspect harbor",
            "change_kind": "design", "author_vendor": "google", "wait_seconds": 10]
        default: return [:]
        }
    }

    private func request(_ r: U25Rig, _ op: String, caller: String = "a",
                         door: String = "agent.sock", extra: [String: Any] = [:]) throws -> [String: Any] {
        let wire: [String: Any] = ["op": op, "caller": caller]
        return try r.home.request(wire.merging(fields(op)) { _, b in b }
            .merging(extra) { _, b in b }, socketName: door)
    }

    private func refused(_ reply: [String: Any], _ reason: String) {
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["exit"] as? Int == 3)
        #expect(reply["error"] as? String == "refused: " + reason)
        #expect(reply["data"] == nil)
    }

    @Test(arguments: ownerOnly)
    func agentDoorRejectsOtherOperations(op: String) throws {
        let r = try U25Rig(); try configure(r)
        refused(try request(r, op), "not served on the agent socket")
        try r.noWork()
    }

    @Test(arguments: ownerOnly + gated + ["ping"])
    func ownerLabelIsNeverAcceptedAtAgentDoor(op: String) throws {
        let r = try U25Rig(); try configure(r)
        refused(try request(r, op, caller: "owner"), "the owner calls on the owner socket")
        try r.noWork()
    }

    @Test func agentPingDoesNotNeedAccess() throws {
        let r = try U25Rig(); try configure(r, access: nil)
        #expect(try request(r, "ping")["ok"] as? Bool == true)
    }

    @Test(arguments: gated, doors)
    func brokerRereadsAccessAndFailsClosed(op: String, door: String) throws {
        let r = try U25Rig(); try configure(r, access: "off")
        try r.restart(environment: [:])
        for access in ["off", "absent", "unreadable"] {
            try configure(r, access: access == "absent" ? nil : "off")
            let config = r.home.url.appendingPathComponent("config.json")
            if access == "unreadable" {
                try FileManager.default.removeItem(at: config)
                try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
            }
            refused(try request(r, op, door: door), "agent access is off")
            if access == "unreadable" { try FileManager.default.removeItem(at: config) }
        }
        try r.noWork()
        try configure(r)
        #expect(try request(r, "list_targets", door: door)["ok"] as? Bool == true)
    }

    @Test(arguments: gated, doors)
    func allowedAgentOperationsStillWork(op: String, door: String) throws {
        let r = try U25Rig(); try configure(r)
        var extra: [String: Any] = [:]
        if ["result", "status", "stop"].contains(op) {
            let data = try r.data(request(r, "ask", door: door))
            extra["id"] = try #require(data["thread"] as? String)
        }
        #expect(try request(r, op, door: door, extra: extra)["ok"] as? Bool == true)
    }

    @Test(arguments: gated)
    func ownerOperationsIgnoreAccessSwitch(op: String) throws {
        let r = try U25Rig(); try configure(r, access: "off")
        var extra: [String: Any] = [:]
        if ["result", "status", "stop"].contains(op) {
            extra["id"] = try #require(r.data(r.base.ask("a"))["thread"] as? String)
        }
        #expect(try request(r, op, caller: "owner", door: "agencil.sock", extra: extra)["ok"] as? Bool == true)
    }

    @Test(arguments: ["status", "result", "stop", "ask"], ["a", "b", "owner"])
    func threadsBelongToRecordedCaller(op: String, caller: String) throws {
        let r = try U25Rig(); try configure(r)
        if op == "stop" { try r.mode("codex", "hang") }
        let thread = try #require(r.data(request(r, "ask",
            extra: ["wait_seconds": op == "stop" ? 0 : 10]))["thread"] as? String)
        let extra: [String: Any] = op == "ask" ? ["thread": thread] : ["id": thread, "wait_seconds": 0]
        let reply = try request(r, op, caller: caller,
            door: caller == "owner" ? "agencil.sock" : "agent.sock", extra: extra)
        if caller == "b" { refused(reply, "not your thread") }
        else { #expect(reply["ok"] as? Bool == true) }
    }

    @Test(arguments: ["status", "result", "stop"], ["a", "b", "owner"])
    func sittingLinksAreSharedButStopsAreOwned(op: String, caller: String) throws {
        let r = try U25Rig(); try configure(r)
        if op == "stop" { try r.mode("a", "hang") }
        let sitting = try #require(r.verdict(request(r, "wake",
            extra: ["wait_seconds": op == "stop" ? 0 : 10]))["sitting"] as? String)
        let reply = try request(r, op, caller: caller,
            door: caller == "owner" ? "agencil.sock" : "agent.sock", extra: ["id": sitting, "wait_seconds": 0])
        if op == "stop" && caller == "b" { refused(reply, "not your thread") }
        else { #expect(reply["ok"] as? Bool == true) }
    }

    // A separate process supplies a real kernel cwd. Request fields cannot substitute for it.
    private func peer(_ r: U25Rig, cwd: URL, wire: [String: Any], deleteCWD: Bool = false) throws -> [String: Any] {
        let json = try u6aText(wire).replacingOccurrences(of: "'", with: "'\\''")
        let quotedCWD = cwd.path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "cd '" + quotedCWD + "' && " +
            (deleteCWD ? "/bin/rmdir '" + quotedCWD + "' && " : "") +
            "printf '%s\\n' '" + json + "' | /usr/bin/nc -w 15 -U '" +
            r.home.url.appendingPathComponent("agent.sock").path + "'"
        let process = try BrokerProcess(["-c", command], home: r.home.url,
            executable: URL(fileURLWithPath: "/bin/sh"))
        let (code, out, _) = try process.finish(20)
        #expect(code == 0)
        return try brokerJSON(Data(out.utf8))
    }

    private func git(_ r: U25Rig, _ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let process = try BrokerProcess(["init", path.path], home: r.home.url,
            executable: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(try process.finish().0 == 0)
    }

    @Test(arguments: ["ask", "wake"], [false, true])
    func missingOrNonGitPeerCWDIsRefused(op: String, deleted: Bool) throws {
        let r = try U25Rig(); try configure(r)
        let cwd = r.home.url.appendingPathComponent("empty-cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        let file = r.home.url.appendingPathComponent("existing-attachment.txt")
        try r.packet.put(file, "U32_CWD_ATTACHMENT")
        let wire = fields(op).merging(["op": op, "caller": "a", "files": [file.path]]) { _, b in b }
        refused(try peer(r, cwd: cwd, wire: wire, deleteCWD: deleted), "file outside the caller's repo")
        try r.noWork()
    }

    @Test(arguments: ["ask", "wake"], [false, true])
    func plainRequestDoesNotRequireGitPeerCWD(op: String, deleted: Bool) throws {
        let r = try U25Rig(); try configure(r)
        let cwd = r.home.url.appendingPathComponent("empty-cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        let wire = fields(op).merging(["op": op, "caller": "a"]) { _, b in b }
        let reply = try peer(r, cwd: cwd, wire: wire, deleteCWD: deleted)
        #expect(reply["error"] as? String != "refused: file outside the caller's repo")
        #expect(reply["ok"] as? Bool == true)
    }

    @Test(arguments: ["ask", "wake"], ["link", "credential"])
    func repoItselfMustResolveInsideAllowedTree(op: String, scenario: String) throws {
        let r = try U25Rig(); try configure(r); try git(r, r.packet.fakeHome)
        let credential = r.packet.fakeHome.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: credential, withIntermediateDirectories: true)
        let link = r.packet.fakeHome.appendingPathComponent("outside-repo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: r.home.url)
        let wire = fields(op).merging(["op": op, "caller": "a",
            "repo": scenario == "link" ? link.path : credential.path]) { _, b in b }
        refused(try peer(r, cwd: r.packet.fakeHome, wire: wire), "file outside the caller's repo")
        try r.noWork()
    }

    @Test(arguments: ["ask", "wake"], ["outside", "link", "repo", "no-git", "second-file"])
    func pathsAreBoundToKernelWorkingDirectory(op: String, scenario: String) throws {
        let r = try U25Rig(); try configure(r); try git(r, r.packet.repo)
        let outside = r.home.url.appendingPathComponent("never-read")
        // A FIFO hangs any reader. Exact refusal within the socket timeout proves admission precedes reading.
        #expect(mkfifo(outside.path, 0o600) == 0)
        let link = r.packet.repo.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var wire = fields(op).merging(["op": op, "caller": "a"]) { _, b in b }
        wire["files"] = [scenario == "link" ? link.path : outside.path]
        if scenario == "second-file" {
            let inside = r.packet.repo.appendingPathComponent("inside.txt")
            // Validate the whole list before opening even an allowed first attachment.
            #expect(mkfifo(inside.path, 0o600) == 0)
            wire["files"] = [inside.path, outside.path]
        }
        if scenario == "repo" { wire["repo"] = r.home.url.path; wire["files"] = [] }
        // Forged cwd and repo cannot grant access to the FIFO.
        wire["cwd"] = r.home.url.path
        let cwd = scenario == "no-git" ? r.home.url : r.packet.repo
        refused(try peer(r, cwd: cwd, wire: wire), "file outside the caller's repo")
        try r.noWork()
    }

    @Test(arguments: [".ssh", ".aws", ".gnupg", ".config/gh", ".claude", ".codex",
        ".agencil", "Library/Keychains"], ["ask", "wake"])
    func credentialFoldersAreDeniedEvenInsidePeerRepo(folder: String, op: String) throws {
        let r = try U25Rig(); try configure(r)
        // U25Rig launches with TEST_SEAMS=1 and HOME=packet.fakeHome, never the real home.
        try git(r, r.packet.fakeHome)
        let path = r.packet.fakeHome.appendingPathComponent(folder).appendingPathComponent("never-read")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(path.path, 0o600) == 0)
        let wire = fields(op).merging(["op": op, "caller": "a", "files": [path.path]]) { _, b in b }
        refused(try peer(r, cwd: r.packet.fakeHome, wire: wire), "file outside the caller's repo")
        var repoWire = wire
        repoWire["files"] = []
        repoWire["repo"] = path.deletingLastPathComponent().path
        refused(try peer(r, cwd: r.packet.fakeHome, wire: repoWire), "file outside the caller's repo")
        try r.noWork()
    }

    @Test(arguments: ["ask", "wake"], [false, true])
    func inRepoAttachmentReachesSeat(op: String, linked: Bool) throws {
        let r = try U25Rig(); try configure(r); try git(r, r.packet.repo)
        let file = r.packet.repo.appendingPathComponent("attachment.txt")
        try r.packet.put(file, "U32_ATTACHED_MARKER")
        let link = r.packet.repo.appendingPathComponent("inside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let wire = fields(op).merging(["op": op, "caller": "a",
            "files": [linked ? link.path : file.path]]) { _, b in b }
        #expect(try peer(r, cwd: r.packet.repo, wire: wire)["ok"] as? Bool == true)
        let prompts = try r.observations(suffix: "prompt").map { try r.text($0) }.joined()
        #expect(prompts.contains("U32_ATTACHED_MARKER"))
    }

    @Test(arguments: ["ask", "wake"])
    func ownerMayAttachOutsideRepo(op: String) throws {
        let r = try U25Rig(); try configure(r)
        let file = r.home.url.appendingPathComponent("owner-attachment")
        try r.packet.put(file, "U32_OWNER_MARKER")
        #expect(try request(r, op, caller: "owner", door: "agencil.sock",
            extra: ["files": [file.path]])["ok"] as? Bool == true)
        #expect(try r.observations(suffix: "prompt").map { try r.text($0) }.joined().contains("U32_OWNER_MARKER"))
    }

    @Test func mcpRequiresAgentDoorAndDoesNotFallBackToOwnerDoor() throws {
        let r = try U25Rig(); try configure(r)
        let server = try BrokerMCP(r.home)
        _ = try server.initialize("2025-06-18")
        func list() throws -> [String: Any] {
            let reply = try server.call("tools/call", ["name": "list_targets", "arguments": [:]] as [String: Any])
            return try #require(reply["result"] as? [String: Any])
        }
        #expect(try list()["isError"] as? Bool == false)
        try FileManager.default.removeItem(at: r.home.url.appendingPathComponent("agent.sock"))
        #expect(try r.home.request(["op": "ping"])["ok"] as? Bool == true)
        #expect(try list()["isError"] as? Bool == true)
    }

    @Test func ownerCLIUsesOwnerDoor() throws {
        let r = try U25Rig(); try configure(r, access: "off")
        try FileManager.default.removeItem(at: r.home.url.appendingPathComponent("agent.sock"))
        let data = try r.base.cliData(["ask", "a", "inspect harbor", "--wait", "10"])
        let id = try #require(data["thread"] as? String)
        let brief = r.home.url.appendingPathComponent("owner.brief")
        try r.packet.put(brief, "change_kind: design\nquestion: inspect harbor\nauthor_vendor: google\n")
        #expect(try r.home.cli(["wake", "panel", "--brief", brief.path, "--wait", "10", "--json"]).0 == 0)
        for args in [["status", id], ["result", id, "--wait", "10"], ["stop", id], ["seats"],
            ["councils"], ["routes"], ["harnesses"], ["models"]] {
            #expect(try r.home.cli(args + ["--json"]).0 == 0)
        }
    }
}
