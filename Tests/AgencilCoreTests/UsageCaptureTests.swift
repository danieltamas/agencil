import Foundation
import Testing
@testable import AgencilCore

/// What a harness's own JSON stream says about a run, read back into tokens and dollars. Fixtures are the shapes the
/// three harnesses write; nothing here starts a process.
@Suite struct UsageCaptureTests {
    private func file(_ name: String, _ text: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: claude

    @Test func claudeResultYieldsAnswerTokensCacheAndDollars() throws {
        let path = try file("answer.txt", """
        {"type":"result","result":"OK","total_cost_usd":0.112621,"usage":{"input_tokens":4,"cache_creation_input_tokens":40000,"cache_read_input_tokens":437,"output_tokens":4}}
        """)
        let read = UsageCapture.read(.claudeResult, answerFile: path)
        #expect(read.answer == "OK")
        let usage = try #require(read.usage)
        #expect(usage.input == 4 && usage.cacheWrite == 40000 && usage.cacheRead == 437 && usage.output == 4)
        #expect(usage.tokensIn == 40441)
        #expect(usage.reportedDollars == 0.112621)
    }

    @Test func claudeWithoutUsageKeepsTheAnswer() throws {
        let path = try file("answer.txt", #"{"type":"result","result":"OK"}"#)
        let read = UsageCapture.read(.claudeResult, answerFile: path)
        #expect(read.answer == "OK")
        #expect(read.usage == nil)
    }

    @Test(arguments: ["", "plain text answer", "{not json", #"{"type":"assistant","result":"x"}"#, #"{"type":"result","result":5}"#, "[1,2]"])
    func claudeStreamsThatAreNotAResultYieldNothing(text: String) throws {
        let read = UsageCapture.read(.claudeResult, answerFile: try file("answer.txt", text))
        #expect(read.answer == nil && read.usage == nil)
    }

    @Test func aMissingFileYieldsNothing() {
        let read = UsageCapture.read(.claudeResult, answerFile: "/nonexistent/answer.txt")
        #expect(read.answer == nil && read.usage == nil)
    }

    @Test func claudeCountsThatAreNegativeFractionalHugeOrBooleanAreNotUsage() throws {
        for bad in ["-1", "1.5", "1e30", "true", "\"7\""] {
            let path = try file("answer.txt", #"{"type":"result","result":"OK","usage":{"input_tokens":\#(bad),"output_tokens":4}}"#)
            let read = UsageCapture.read(.claudeResult, answerFile: path)
            #expect(read.answer == "OK", "answer survives \(bad)")
            #expect(read.usage == nil, "\(bad) is not a token count")
        }
    }

    @Test func claudeDollarsThatAreNegativeOrNotNumbersAreDropped() throws {
        for bad in ["-0.5", "\"1\"", "null", "true"] {
            let path = try file("answer.txt", #"{"type":"result","result":"OK","total_cost_usd":\#(bad),"usage":{"input_tokens":1,"output_tokens":1}}"#)
            #expect(UsageCapture.read(.claudeResult, answerFile: path).usage?.reportedDollars == nil, "\(bad)")
        }
    }

    // MARK: codex

    @Test func codexCachedTokensAreSplitOutOfInput() throws {
        let answer = try file("answer.txt", "OK")
        try """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.completed","usage":{"input_tokens":22000,"cached_input_tokens":20000,"output_tokens":5}}
        """.write(toFile: UsageFormat.eventsFile(besides: answer), atomically: true, encoding: .utf8)
        let read = UsageCapture.read(.codexEvents, answerFile: answer)
        #expect(read.answer == nil, "the answer stays in the -o file")
        let usage = try #require(read.usage)
        #expect(usage.input == 2000 && usage.cacheRead == 20000 && usage.output == 5)
        #expect(usage.tokensIn == 22000)
        #expect(usage.reportedDollars == nil)
    }

    @Test func codexTurnsAreSummedAndCachedNeverExceedsInput() throws {
        let answer = try file("answer.txt", "OK")
        try """
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":500,"output_tokens":1}}
        {"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2}}
        """.write(toFile: UsageFormat.eventsFile(besides: answer), atomically: true, encoding: .utf8)
        let usage = try #require(UsageCapture.read(.codexEvents, answerFile: answer).usage)
        #expect(usage.input == 10 && usage.cacheRead == 100 && usage.output == 3)
    }

    @Test func codexWithoutACompletedTurnYieldsNoUsage() throws {
        let answer = try file("answer.txt", "OK")
        try "{\"type\":\"turn.failed\"}\nnot json\n".write(toFile: UsageFormat.eventsFile(besides: answer), atomically: true, encoding: .utf8)
        #expect(UsageCapture.read(.codexEvents, answerFile: answer).usage == nil)
    }

    @Test func codexWithoutAnEventsFileYieldsNoUsage() throws {
        #expect(UsageCapture.read(.codexEvents, answerFile: try file("answer.txt", "OK")).usage == nil)
    }

    // MARK: opencode

    @Test func opencodeStepsAreSummedAndTextPartsJoined() throws {
        let path = try file("stdout.txt", """
        {"type":"step_start","part":{"type":"step-start"}}
        {"type":"text","part":{"text":"Hello"}}
        {"type":"step_finish","part":{"tokens":{"input":100,"output":5,"reasoning":3,"cache":{"read":10,"write":2}},"cost":0.002}}
        {"type":"text","part":{"text":"World"}}
        {"type":"step_finish","part":{"tokens":{"input":20,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0.001}}
        """)
        let read = UsageCapture.read(.opencodeEvents, answerFile: path)
        #expect(read.answer == "Hello\nWorld")
        let usage = try #require(read.usage)
        #expect(usage.input == 120 && usage.output == 9 && usage.cacheRead == 10 && usage.cacheWrite == 2)
        #expect(abs((usage.reportedDollars ?? 0) - 0.003) < 1e-12)
    }

    @Test func opencodeCostZeroIsUnpricedNotFree() throws {
        let path = try file("stdout.txt", """
        {"type":"text","part":{"text":"OK"}}
        {"type":"step_finish","part":{"tokens":{"input":123,"output":7},"cost":0}}
        """)
        let usage = try #require(UsageCapture.read(.opencodeEvents, answerFile: path).usage)
        #expect(usage.reportedDollars == nil)
        #expect(usage.input == 123 && usage.output == 7)
    }

    @Test func opencodeErrorEventYieldsNoUsageAndNoAnswer() throws {
        let path = try file("stdout.txt", #"{"type":"error","error":{"message":"boom"}}"#)
        let read = UsageCapture.read(.opencodeEvents, answerFile: path)
        #expect(read.answer == nil && read.usage == nil)
    }

    @Test func opencodeAnswerWithoutAStepFinishKeepsTheAnswerOnly() throws {
        let read = UsageCapture.read(.opencodeEvents, answerFile: try file("stdout.txt", #"{"type":"text","part":{"text":"OK"}}"#))
        #expect(read.answer == "OK" && read.usage == nil)
    }

    // MARK: cost

    private let price = ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: nil)

    @Test func harnessDollarsBeatThePriceList() {
        var usage = HarnessUsage(input: 1000, cacheRead: 0, cacheWrite: 0, output: 1000)
        usage.reportedDollars = 0.5
        let cost = UsageCapture.cost(usage, price: price, subscription: false)
        #expect(cost?.dollars == 0.5 && cost?.basis == "reported")
    }

    @Test func aSubscriptionRunIsAlwaysAnEstimate() {
        var usage = HarnessUsage(input: 1000, cacheRead: 0, cacheWrite: 0, output: 1000)
        usage.reportedDollars = 0.5
        #expect(UsageCapture.cost(usage, price: price, subscription: true)?.basis == "estimated, subscription")
        usage.reportedDollars = nil
        #expect(UsageCapture.cost(usage, price: price, subscription: true)?.basis == "estimated, subscription")
    }

    @Test func listPriceIsPerMillionTokens() throws {
        let usage = HarnessUsage(input: 2000, cacheRead: 20000, cacheWrite: 0, output: 1000)
        let cost = try #require(UsageCapture.cost(usage, price: price, subscription: false))
        let expected: Double = (10_000.0 + 25_000.0 + 10_000.0) / 1_000_000
        #expect(abs(cost.dollars - expected) < 1e-12)
        #expect(cost.basis == "estimated")
    }

    @Test func noPriceAndNoDollarsIsUnknownNeverZero() {
        #expect(UsageCapture.cost(HarnessUsage(input: 10, cacheRead: 0, cacheWrite: 0, output: 10), price: nil, subscription: false) == nil)
    }

    @Test func cacheTokensWithoutACachePriceAreUnknownNotGuessed() {
        let withWrite = HarnessUsage(input: 10, cacheRead: 0, cacheWrite: 5, output: 10)
        #expect(UsageCapture.cost(withWrite, price: price, subscription: false) == nil)
        let noCache = ModelPrice(input: 5, output: 25)
        let withRead = HarnessUsage(input: 10, cacheRead: 5, cacheWrite: 0, output: 10)
        #expect(UsageCapture.cost(withRead, price: noCache, subscription: false) == nil)
        #expect(UsageCapture.cost(HarnessUsage(input: 10, cacheRead: 0, cacheWrite: 0, output: 10), price: noCache, subscription: false) != nil)
    }

    @Test func aProviderPrefixedModelMatchesTheBareListEntry() {
        let entries = [PriceListEntry(id: "gpt-5.5", provider: "openai", price: price),
                       PriceListEntry(id: "opencode/glm", provider: "x", price: ModelPrice(input: 1, output: 1))]
        #expect(ModelPriceList.price(of: "gpt-5.5", in: entries) == price)
        #expect(ModelPriceList.price(of: "openai/gpt-5.5", in: entries) == price)
        #expect(ModelPriceList.price(of: "opencode/glm", in: entries) == ModelPrice(input: 1, output: 1))
        #expect(ModelPriceList.price(of: "openai/unknown", in: entries) == nil)
    }

    // MARK: invocation

    private func seat(_ harness: String) throws -> Seat {
        try SeatConfig(values: ["seats": #"[{"name":"s","harness":"\#(harness)","model":"m","role":"answerer"}]"#]).seats[0]
    }

    @Test func theProbeInvocationStaysPlainText() throws {
        for harness in ["claude", "codex", "opencode"] {
            let plain = try #require(try Adapter.command(seat: seat(harness), executable: "/x", prompt: "p", answerFile: "/tmp/a", runDirectory: NSTemporaryDirectory()))
            #expect(plain.usage == nil)
            #expect(!plain.argv.contains("--json") && !plain.argv.contains("--output-format") && !plain.argv.contains("--format"))
        }
    }

    @Test func theAskInvocationAsksForTheStructuredStream() throws {
        let formats: [String: UsageFormat] = ["claude": .claudeResult, "codex": .codexEvents, "opencode": .opencodeEvents]
        for (harness, format) in formats {
            let ask = try #require(try Adapter.command(seat: seat(harness), executable: "/x", prompt: "p", answerFile: "/tmp/a",
                                                       runDirectory: NSTemporaryDirectory(), reportUsage: true))
            #expect(ask.usage == format)
            #expect(ask.argv.contains("json") || ask.argv.contains("--json"))
        }
    }
}
