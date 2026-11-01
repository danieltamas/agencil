import Foundation
import Testing

/// The read-only `detail` op (docs/AGENT-API.md "detail") and the panel op's split between direct asks and a sitting's
/// per-round seat threads, against a real broker, ledger and stub harnesses.
@Suite(.serialized)
struct DetailOpTests {
    private let project = "harbor-checkout  ~/Sites/harbor-checkout"

    private func ask(_ r: U25Rig, question: String = "Is the harbor safe?", project: Any? = nil, extra: [String: Any] = [:]) throws -> [String: Any] {
        var fields: [String: Any] = ["target": "a", "question": question, "wait_seconds": 10]
        if let project { fields["project"] = project }
        return try r.data(r.request("ask", fields.merging(extra) { _, new in new }))
    }

    private func detail(_ r: U25Rig, _ id: String) throws -> [String: Any] { try r.data(r.request("detail", ["id": id])) }

    private func wake(_ r: U25Rig, project: Any? = nil) throws -> [String: Any] {
        var fields: [String: Any] = ["council": "panel", "question": "inspect harbor", "change_kind": "design", "author_vendor": "google",
                                     "wait_seconds": 10]
        if let project { fields["project"] = project }
        return try r.verdict(r.request("wake", fields))
    }

    private func refusal(_ reply: [String: Any]) -> String? {
        reply["ok"] as? Bool == false ? reply["error"] as? String : nil
    }

    // MARK: thread

    @Test func aThreadDetailHasTheExchangeAskerSeatModelAndProject() throws {
        let r = try U25Rig()
        let asked = try ask(r, project: project)
        let id = try #require(asked["thread"] as? String)
        let data = try detail(r, id)
        #expect(data["thread"] as? String == id)
        #expect(data["caller"] as? String == "owner")
        #expect(data["seat"] as? String == "a")
        #expect(data["model"] as? String == "harbor-model")
        #expect(data["harness"] as? String == "codex")
        #expect(data["project"] as? String == project)
        let exchanges = try #require(data["exchanges"] as? [[String: Any]])
        #expect(exchanges.count == 1)
        #expect(exchanges[0]["seq"] as? Int == 1)
        #expect(exchanges[0]["question"] as? String == "Is the harbor safe?")
        #expect(exchanges[0]["answer"] as? String == "OK")
        #expect(exchanges[0]["state"] as? String == "answered")
        #expect(exchanges[0]["reason"] == nil)
    }

    @Test func tokensAndCostTheSeatNeverReportedAreLeftOutNotZero() throws {
        let r = try U25Rig()
        let id = try #require(try ask(r)["thread"] as? String)
        let exchange = try #require(try detail(r, id)["exchanges"] as? [[String: Any]]).first
        #expect(exchange?["tokens"] == nil)
        #expect(exchange?["cost_usd"] == nil)
    }

    @Test func aThreadAskedWithoutAProjectHasNoProjectKey() throws {
        let r = try U25Rig()
        let id = try #require(try ask(r)["thread"] as? String)
        #expect(try detail(r, id)["project"] == nil)
    }

    @Test func aFollowUpAddsAnOrderedExchangeToTheSameThread() throws {
        let r = try U25Rig()
        let id = try #require(try ask(r, question: "first question")["thread"] as? String)
        _ = try ask(r, question: "second question", extra: ["thread": id])
        let exchanges = try #require(try detail(r, id)["exchanges"] as? [[String: Any]])
        #expect(exchanges.map { $0["seq"] as? Int } == [1, 2])
        #expect(exchanges.map { $0["question"] as? String } == ["first question", "second question"])
    }

    @Test func aFailedExchangeCarriesItsReasonAndNoAnswer() throws {
        let r = try U25Rig()
        try r.put("codex.ask", "OK")
        try r.mode("codex", "busy")
        let reply = try r.request("ask", ["target": "a", "question": "will fail", "wait_seconds": 10])
        let result = try #require(reply["data"] as? [String: Any])
        let id = try #require(result["thread"] as? String)
        let exchange = try #require(try detail(r, id)["exchanges"] as? [[String: Any]]).first
        #expect(exchange?["state"] as? String == "failed")
        let reason = exchange?["reason"] as? String ?? ""
        #expect(!reason.isEmpty)
        #expect(exchange?["answer"] == nil)
    }

    @Test func aLongQuestionAndAnswerAreCappedNotRefused() throws {
        let r = try U25Rig()
        let long = String(repeating: "q", count: 40_000)
        let id = try #require(try ask(r, question: long)["thread"] as? String)
        let exchange = try #require(try detail(r, id)["exchanges"] as? [[String: Any]]).first
        let question = try #require(exchange?["question"] as? String)
        #expect(question.count < long.count && question.count >= 1000)
    }

    // MARK: ids

    @Test func anUnknownIdIsARefusalForEveryShape() throws {
        let r = try U25Rig()
        for id in ["th_0000000000000000", "sit_0000000000000000", "bogus", "", "AG-1-1"] {
            let reply = try r.request("detail", ["id": id])
            #expect(reply["ok"] as? Bool == false, "\(id)")
            #expect(refusal(reply)?.contains("unknown id") == true, "\(id)")
            #expect(reply["data"] == nil)
        }
    }

    @Test func aMissingIdIsAUsageRefusal() throws {
        let r = try U25Rig()
        let reply = try r.request("detail")
        #expect(reply["ok"] as? Bool == false)
        #expect(refusal(reply)?.contains("usage") == true)
        #expect(try r.request("detail", ["id": 7])["ok"] as? Bool == false)
    }

    @Test func aSqlLookingIdIsOnlyUnknown() throws {
        let r = try U25Rig()
        _ = try ask(r)
        for id in ["th_' OR '1'='1", "sit_%", "th_%"] {
            let reply = try r.request("detail", ["id": id])
            #expect(reply["ok"] as? Bool == false, "\(id)")
        }
    }

    // MARK: sitting

    @Test func aSittingDetailHasBriefVerdictVotesRoundsAndSnapshot() throws {
        let r = try U25Rig()
        let verdict = try wake(r, project: project)
        #expect(verdict["verdict"] as? String == "PASS")
        let id = try #require(verdict["sitting"] as? String)
        let data = try detail(r, id)
        #expect(data["sitting"] as? String == id)
        #expect(data["council"] as? String == "panel")
        #expect(data["state"] as? String == "done")
        #expect(data["project"] as? String == project)
        #expect(data["snapshot"] as? String == verdict["snapshot"] as? String)
        #expect((data["brief"] as? String)?.contains("inspect harbor") == true)
        #expect(data["change_kind"] as? String == "design")
        #expect(data["question"] as? String == "inspect harbor")
        let result = try #require(data["verdict"] as? [String: Any])
        #expect(result["verdict"] as? String == "PASS")
        #expect(!(try #require(result["reasons"] as? [String])).isEmpty)
        let votes = try #require(result["votes"] as? [[String: Any]])
        #expect(Set(votes.compactMap { $0["seat"] as? String }) == ["a", "b", "c"])
        #expect(votes.allSatisfy { $0["vote"] as? String == "approve" })
    }

    @Test func everyRoundListsEverySeatsAnswerWithModelAndHarness() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["rounds": ["rebuttal": true]]))
        let id = try #require(try wake(r)["sitting"] as? String)
        let rounds = try #require(try detail(r, id)["rounds"] as? [[String: Any]])
        #expect(rounds.map { $0["round"] as? String } == ["blind", "rebuttal"])
        for round in rounds {
            let seats = try #require(round["seats"] as? [[String: Any]])
            #expect(Set(seats.compactMap { $0["seat"] as? String }) == ["a", "b", "c"])
            for seat in seats {
                #expect(seat["state"] as? String == "answered")
                #expect(!(seat["answer"] as? String ?? "").isEmpty)
                #expect(seat["model"] as? String == "harbor-model")
                #expect(!(seat["harness"] as? String ?? "").isEmpty)
                #expect(!(seat["thread"] as? String ?? "").isEmpty)
            }
        }
    }

    @Test func claimsReachTheDetailWithEvidenceFileAndSeat() throws {
        let r = try U25Rig()
        try r.configure(council: u7aCouncil(["rule": "any_blocker"]))
        try r.reply("a", answer: u7aAnswer("block", claims: [u7aClaim("p1", evidence: "double charge")]))
        let verdict = try wake(r)
        #expect(verdict["verdict"] as? String == "BLOCK")
        let id = try #require(verdict["sitting"] as? String)
        let result = try #require(try detail(r, id)["verdict"] as? [String: Any])
        let claim = try #require((result["claims"] as? [[String: Any]])?.first)
        #expect(claim["evidence"] as? String == "double charge")
        #expect(claim["file"] as? String == "src/main.swift")
        #expect(claim["seat"] as? String == "a")
        #expect(claim["severity"] as? String == "p1")
    }

    @Test func aDoneSittingStaysRetrievableAndReadingChangesNothing() throws {
        let r = try U25Rig()
        let first = try #require(try wake(r)["sitting"] as? String)
        let before = try detail(r, first)
        _ = try wake(r)
        let counts = try r.sql("SELECT (SELECT count(*) FROM runs), (SELECT count(*) FROM threads), (SELECT count(*) FROM exchanges);")
        let again = try detail(r, first)
        #expect(NSDictionary(dictionary: again).isEqual(to: before))
        #expect(try r.sql("SELECT (SELECT count(*) FROM runs), (SELECT count(*) FROM threads), (SELECT count(*) FROM exchanges);") == counts)
    }

    @Test func aSittingKeepsItsSeatsApartFromAnotherSittingsRounds() throws {
        let r = try U25Rig()
        let one = try #require(try wake(r)["sitting"] as? String)
        let two = try #require(try wake(r)["sitting"] as? String)
        let threadsOne = try seatThreads(r, one), threadsTwo = try seatThreads(r, two)
        #expect(threadsOne.count == 3 && threadsTwo.count == 3)
        #expect(threadsOne.isDisjoint(with: threadsTwo))
    }

    private func seatThreads(_ r: U25Rig, _ sitting: String) throws -> Set<String> {
        let rounds = try #require(try detail(r, sitting)["rounds"] as? [[String: Any]])
        return Set(rounds.flatMap { ($0["seats"] as? [[String: Any]] ?? []).compactMap { $0["thread"] as? String } })
    }

    /// Two rounds of one sitting written inside the same second, the later round's thread with the smaller id: the
    /// order the screen shows is the order the rounds were held, not the order of random ids.
    @Test func roundsAreShownInTheOrderTheyWereHeldWhenTheirThreadsShareASecond() throws {
        let r = try U8Rig()
        let stamp = "2030-01-01T12:00:00Z"
        func prompt(_ round: String) -> String {
            "'ROUND: \(round)' || char(10) || 'SITTING: sit_1' || char(10) || 'SEAT: a' || char(10) || 'SNAPSHOT: s' || char(10) || 'CHANGE KIND: design' || char(10) || 'QUESTION:' || char(10) || 'q'"
        }
        try r.sql("""
            INSERT INTO runs(id,kind,status,started_at,ended_at) VALUES('sit_1','sitting','PASS','\(stamp)','\(stamp)');
            INSERT INTO sittings(id, no, council, state, round, author_vendor, snapshot_id, reason, verdict, created_at, ended_at)
              VALUES('sit_1',1,'panel','PASS','blind','google','snapshot','','PASS','\(stamp)','\(stamp)');
            INSERT INTO runs(id,kind,status,started_at,ended_at) VALUES('th_zz','thread','answered','\(stamp)','\(stamp)');
            INSERT INTO threads VALUES('th_zz','a','a','owner',NULL,'\(stamp)');
            INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at) VALUES('th_zz',1,\(prompt("blind")),'first','answered','\(stamp)');
            INSERT INTO runs(id,kind,status,started_at,ended_at) VALUES('th_aa','thread','answered','\(stamp)','\(stamp)');
            INSERT INTO threads VALUES('th_aa','a','a','owner',NULL,'\(stamp)');
            INSERT INTO exchanges(thread_id,seq,question,answer,state,created_at) VALUES('th_aa',1,\(prompt("rebuttal")),'second','answered','\(stamp)');
            """)
        let data = try r.council.base.data(r.home.request(["op": "detail", "id": "sit_1"]))
        let rounds = try #require(data["rounds"] as? [[String: Any]])
        #expect(rounds.map { $0["round"] as? String } == ["blind", "rebuttal"])
        let listed = try r.council.base.data(r.home.request(["op": "panel"]))["threads"] as? [[String: Any]]
        #expect(listed?.isEmpty == true)
    }

    // MARK: panel

    @Test func aSittingsRoundThreadsAreHiddenFromThePanelsThreadsButInsideTheSittingDetail() throws {
        let r = try U25Rig()
        let sitting = try #require(try wake(r)["sitting"] as? String)
        let direct = try #require(try ask(r, question: "a direct question")["thread"] as? String)
        let panel = try r.data(r.request("panel"))
        let listed = try #require(panel["threads"] as? [[String: Any]])
        #expect(listed.compactMap { $0["id"] as? String } == [direct])
        #expect((panel["sittings"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [sitting])
        let hidden = try seatThreads(r, sitting)
        #expect(hidden.count == 3 && !hidden.contains(direct))
        #expect(try r.sql("SELECT count(*) FROM threads;") == "4\n")
    }

    @Test func aDirectAskWhoseQuestionJustStartsWithRoundStaysVisible() throws {
        let r = try U25Rig()
        let id = try #require(try ask(r, question: "ROUND: table talk about lunch")["thread"] as? String)
        let listed = try #require(try r.data(r.request("panel"))["threads"] as? [[String: Any]])
        #expect(listed.compactMap { $0["id"] as? String } == [id])
    }

    @Test func aRoundThreadStillOpensByItsIdAsAThread() throws {
        let r = try U25Rig()
        let sitting = try #require(try wake(r)["sitting"] as? String)
        let thread = try #require(try seatThreads(r, sitting).first)
        let data = try detail(r, thread)
        let question = try #require((data["exchanges"] as? [[String: Any]])?.first?["question"] as? String)
        #expect(question.hasPrefix("ROUND: blind"))
    }

    // MARK: project origin

    @Test func aProjectThatIsNotShortPrintableTextIsNotRecorded() throws {
        let r = try U25Rig()
        for bad in [String(repeating: "x", count: 301), "two\nlines", "bell\u{7}", "", 42] as [Any] {
            let id = try #require(try ask(r, project: bad)["thread"] as? String)
            #expect(try detail(r, id)["project"] == nil, "\(bad)")
        }
        let id = try #require(try wake(r, project: "two\nlines")["sitting"] as? String)
        #expect(try detail(r, id)["project"] == nil)
    }

    @Test func theProjectStaysInTheLedgerAndIsNeverGivenToAnySeat() throws {
        let r = try U25Rig()
        let marker = "private-origin-marker"
        _ = try ask(r, project: "\(marker)  ~/Sites/\(marker)")
        _ = try wake(r, project: "\(marker)  ~/Sites/\(marker)")
        let prompts = r.observations(suffix: "prompt")
        #expect(prompts.count >= 4)
        for url in prompts { #expect(!(try r.text(url)).contains(marker)) }
        for url in r.observations(suffix: "argv") { #expect(!(try r.text(url)).contains(marker)) }
        #expect(try r.sql("SELECT count(*) FROM run_origins;") == "2\n")
    }

    @Test func aFollowUpDoesNotChangeTheThreadsOriginalProject() throws {
        let r = try U25Rig()
        let id = try #require(try ask(r, project: project)["thread"] as? String)
        _ = try ask(r, question: "again", project: "other  ~/other", extra: ["thread": id])
        #expect(try detail(r, id)["project"] as? String == project)
    }

    // MARK: CLI

    @Test func theCLIDetailPrintsTheThreadAndTheSitting() throws {
        let r = try U25Rig()
        let thread = try #require(try ask(r)["thread"] as? String)
        let sitting = try #require(try wake(r)["sitting"] as? String)
        for (id, key) in [(thread, "thread"), (sitting, "sitting")] {
            let (out, _) = try r.cli(["detail", id, "--json"], exit: 0)
            let envelope = try brokerJSON(Data(out.utf8))
            #expect(envelope["ok"] as? Bool == true)
            #expect((envelope["data"] as? [String: Any])?[key] as? String == id)
        }
    }

    @Test func theCLIDetailOfAnUnknownIdFailsAndWithoutOrWithTooManyIdsIsUsage() throws {
        let r = try U25Rig()
        let (_, unknownErr) = try r.cli(["detail", "th_0000000000000000"], exit: 64)
        #expect(unknownErr.contains("unknown id"))
        _ = try r.cli(["detail"], exit: 64)
        _ = try r.cli(["detail", "th_1", "th_2"], exit: 64)
    }

    @Test func theCLIAskRecordsTheCallersGitTopLevelAsTheProject() throws {
        let r = try U25Rig()
        let (out, _) = try r.cli(["ask", "a", "from the cli", "--wait", "10", "--json"], exit: 0)
        let id = try #require((try brokerJSON(Data(out.utf8))["data"] as? [String: Any])?["thread"] as? String)
        let expected = try gitTopLabel()
        let recorded = try detail(r, id)["project"] as? String
        #expect(recorded == expected)
    }

    /// The test process's own working directory as git sees it, computed independently of ProjectLabel.
    private func gitTopLabel() throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let top = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let home = NSHomeDirectory()
        let shown = top == home || top.hasPrefix(home + "/") ? "~" + top.dropFirst(home.count) : top
        return "\(URL(fileURLWithPath: top).lastPathComponent)  \(shown)"
    }
}
