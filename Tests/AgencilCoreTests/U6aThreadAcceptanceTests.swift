import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct U6aThreadAcceptanceTests {
    @Test func answeredResultAndStatusRemainReadableByCLI() throws {
        let rig = try U6aRig()
        let answer = try rig.answered(rig.ask())
        let id = try #require(answer["thread"] as? String)
        let result = try rig.cliData(["result", id, "--wait", "10"])
        #expect(result["state"] as? String == "answered")
        #expect(result["answer"] as? String == "u6a answer")
        let status = try rig.cliData(["status", id])
        #expect(status["state"] as? String == "answered")
        #expect(answer["substituted"] is NSNull)
    }

    @Test func shortCLIWaitReturnsPendingExitTwoThenLongResultAnswers() throws {
        let rig = try U6aRig(mode: "slow")
        let pending = try rig.cliData(["ask", "primary", "question", "--wait", "0"], exit: 2)
        #expect(pending["state"] as? String == "pending")
        let id = try #require(pending["thread"] as? String)
        let result = try rig.cliData(["result", id, "--wait", "10"])
        #expect(result["state"] as? String == "answered")
        #expect(result["answer"] as? String == "u6a answer")
    }

    @Test func nonzeroSeatExitIsFailedWithReasonAndCLIExitFour() throws {
        let rig = try U6aRig(mode: "fail")
        let data = try rig.data(rig.ask())
        #expect(data["state"] as? String == "failed")
        let reason = try #require(data["reason"] as? String)
        #expect(!reason.isEmpty)
        #expect(reason.contains("17") || reason.contains("u6a deliberate failure"))
        let id = try #require(data["thread"] as? String)
        let result = try rig.cliData(["result", id], exit: 4)
        #expect(result["state"] as? String == "failed")
        #expect(result["reason"] as? String == reason)
    }

    @Test func unknownThreadIsUsageErrorExit64() throws {
        let rig = try U6aRig()
        let (code, _, _) = try rig.home.cli(["result", "th_0000000000000000", "--wait", "0"])
        #expect(code == 64)
        rig.noAnswerSpawned()
    }

    @Test func followupKeepsSeatAndOrderedTranscriptAndRejectsAnotherSeat() throws {
        let rig = try U6aRig(["codex", "hermes"])
        try rig.config(seats: [u6aSeat(), u6aSeat("other", "hermes")], routes: [u6aRoute(), u6aRoute("other")])
        let first = try rig.answered(rig.ask(question: "first question"))
        let id = try #require(first["thread"] as? String)
        let second = try rig.cliData(["ask", "primary", "second question", "--thread", id, "--wait", "10"])
        #expect(second["seat"] as? String == "primary")
        #expect(second["thread"] as? String == id)
        let prompt = try rig.contents()
        let asked = try #require(prompt.range(of: "ASKED:"))
        let firstQuestion = try #require(prompt.range(of: "first question", range: asked.upperBound..<prompt.endIndex))
        let answered = try #require(prompt.range(of: "ANSWERED:", range: firstQuestion.upperBound..<prompt.endIndex))
        let oldAnswer = try #require(prompt.range(of: "u6a answer", range: answered.upperBound..<prompt.endIndex))
        let newQuestion = try #require(prompt.range(of: "second question", range: oldAnswer.upperBound..<prompt.endIndex))
        #expect(newQuestion.lowerBound > oldAnswer.lowerBound)
        let before = prompt
        let (code, _, _) = try rig.home.cli(["ask", "other", "wrong seat", "--thread", id])
        #expect(code == 64)
        #expect(try rig.contents() == before)
    }

    @Test func followupKeepsSubstitutedSeatWhileOriginalRemainsUnusableAndRechecksRoute() throws {
        let rig = try U6aRig(["codex", "claude", "hermes"], mode: "codex-out")
        let seats = [u6aSeat(), u6aSeat("backup", "claude"), u6aSeat("new-backup", "hermes")]
        try rig.config(seats: seats, routes: [u6aRoute(fallbacks: ["backup", "new-backup"])])
        let first = try rig.answered(rig.ask(), seat: "backup")
        let id = try #require(first["thread"] as? String)
        // Reordering fallbacks must not move an existing thread to a different seat.
        try rig.config(seats: seats, routes: [u6aRoute(fallbacks: ["new-backup", "backup"])])
        let second = try rig.answered(rig.ask("backup", question: "followup", extra: ["thread": id]), seat: "backup")
        #expect(second["thread"] as? String == id)
        try rig.config(seats: seats, routes: [])
        rig.refused(try rig.ask("backup", extra: ["thread": id]),
                    "refused: no route from owner to backup", exit: 3)
    }

    @Test func ownerCLIAsOverridesCallerButSocketCallerCannotImpersonateOwner() throws {
        let rig = try U6aRig()
        try rig.config(routes: [u6aRoute(callers: ["maya"])])
        _ = try rig.cliData(["ask", "primary", "question", "--as", "maya", "--wait", "10"])
        rig.refused(try rig.ask(caller: "claude", extra: ["as": "maya"]),
                    "refused: no route from claude to primary", exit: 3)
    }

    @Test func successfulAnswerLeavesNoLeaderOrGroupMemberAlive() throws {
        let rig = try U6aRig()
        _ = try rig.answered(rig.ask())
        let pids = try rig.contents(".pids").split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == 2)
        try brokerPoll(12) { pids.allSatisfy { !brokerAlive($0) } }
    }

    @Test func stopKillsWholeSlowProcessGroupAndMakesThreadFailedStopped() throws {
        let rig = try U6aRig(mode: "stop")
        let pending = try rig.data(rig.ask(extra: ["wait_seconds": 0]))
        let id = try #require(pending["thread"] as? String)
        try brokerPoll(12) { FileManager.default.fileExists(atPath: rig.record.path + ".pids") }
        let pids = try rig.contents(".pids").split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == 2)
        #expect(pids.allSatisfy { brokerAlive($0) })
        let (code, _, _) = try rig.home.cli(["stop", id])
        #expect(code == 0)
        try brokerPoll(12) { pids.allSatisfy { !brokerAlive($0) } }
        let result = try rig.cliData(["result", id, "--wait", "10"], exit: 4)
        #expect(result["state"] as? String == "failed")
        #expect(result["reason"] as? String == "stopped")
    }
}
