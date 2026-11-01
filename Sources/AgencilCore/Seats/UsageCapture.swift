import Foundation

/// What a harness reported for one run. `input` counts uncached tokens; the cache tokens are kept apart because
/// they are priced apart.
struct HarnessUsage: Equatable, Sendable {
    var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
    /// Dollars the harness itself put on the run; nil when it said nothing.
    var reportedDollars: Double?

    var tokensIn: Int { input + cacheRead + cacheWrite }
}

/// The machine-readable stream a harness can write beside its answer. Each reader takes only what the harness
/// documents about itself in that stream; anything it cannot read yields no usage, and the plain answer path stays.
public enum UsageFormat: Equatable, Sendable {
    /// `claude -p --output-format json`: one result object holding the answer and the usage.
    case claudeResult
    /// `codex exec --json`: events on stdout; the answer still goes to the `-o` file.
    case codexEvents
    /// `opencode run --format json`: events on stdout, one `text` part per piece of the answer and a `step-finish` per step.
    case opencodeEvents

    /// The file the codex events are written to, beside the answer file; the other formats write to the answer file itself.
    static func eventsFile(besides answerFile: String) -> String {
        URL(fileURLWithPath: answerFile).deletingLastPathComponent().appendingPathComponent("events.jsonl").path
    }
}

enum UsageCapture {
    /// The answer the stream carries (nil when the answer lives elsewhere or the stream is not the expected shape) and its usage.
    static func read(_ format: UsageFormat, answerFile: String) -> (answer: String?, usage: HarnessUsage?) {
        let path = format == .codexEvents ? UsageFormat.eventsFile(besides: answerFile) : answerFile
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (nil, nil) }
        switch format {
        case .claudeResult: return claude(text)
        case .codexEvents: return (nil, codex(text))
        case .opencodeEvents: return opencode(text)
        }
    }

    private static func object(_ text: some StringProtocol) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let whole = number.intValue
        return whole >= 0 && Double(whole) == number.doubleValue && whole <= OllamaClient.countLimit ? whole : nil
    }

    private static func dollars(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func claude(_ text: String) -> (String?, HarnessUsage?) {
        guard let result = object(text), result["type"] as? String == "result", let answer = result["result"] as? String else { return (nil, nil) }
        guard let usage = result["usage"] as? [String: Any], let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]) else {
            return (answer, nil)
        }
        return (answer, HarnessUsage(input: input, cacheRead: count(usage["cache_read_input_tokens"]) ?? 0,
                                     cacheWrite: count(usage["cache_creation_input_tokens"]) ?? 0, output: output,
                                     reportedDollars: dollars(result["total_cost_usd"])))
    }

    /// `input_tokens` already contains the cached ones; the cached part is split out so it can be priced apart.
    private static func codex(_ text: String) -> HarnessUsage? {
        var total = HarnessUsage(), seen = false
        for line in text.split(separator: "\n") {
            guard let event = object(line), event["type"] as? String == "turn.completed", let usage = event["usage"] as? [String: Any],
                  let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]) else { continue }
            let cached = min(count(usage["cached_input_tokens"]) ?? 0, input)
            total.input += input - cached
            total.cacheRead += cached
            total.output += output
            seen = true
        }
        return seen ? total : nil
    }

    /// Reasoning tokens are billed as output. A step with cost 0 is a model opencode has no price for, not a free run.
    private static func opencode(_ text: String) -> (String?, HarnessUsage?) {
        var pieces: [String] = [], total = HarnessUsage(), seen = false, dollarsSpent = 0.0
        for line in text.split(separator: "\n") {
            guard let event = object(line), let part = event["part"] as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "text": if let piece = part["text"] as? String { pieces.append(piece) }
            case "step_finish":
                guard let tokens = part["tokens"] as? [String: Any], let input = count(tokens["input"]), let output = count(tokens["output"]) else { continue }
                let cache = tokens["cache"] as? [String: Any]
                total.input += input
                total.output += output + (count(tokens["reasoning"]) ?? 0)
                total.cacheRead += count(cache?["read"]) ?? 0
                total.cacheWrite += count(cache?["write"]) ?? 0
                dollarsSpent += dollars(part["cost"]) ?? 0
                seen = true
            default: continue
            }
        }
        total.reportedDollars = dollarsSpent > 0 ? dollarsSpent : nil
        return (pieces.isEmpty ? nil : pieces.joined(separator: "\n"), seen ? total : nil)
    }

    /// The figure stored with a run: the harness's own dollars when it gave them, else the list price of the model
    /// when the model has one. A subscription run is never billed per token, so its figure is always an estimate.
    static func cost(_ usage: HarnessUsage, price: ModelPrice?, subscription: Bool) -> (dollars: Double, basis: String)? {
        let estimated = subscription ? "estimated, subscription" : "estimated"
        if let reported = usage.reportedDollars { return (reported, subscription ? estimated : "reported") }
        guard let price, usage.cacheRead == 0 || price.cacheRead != nil, usage.cacheWrite == 0 || price.cacheWrite != nil else { return nil }
        let perMillion = Double(usage.input) * price.input + Double(usage.output) * price.output
            + Double(usage.cacheRead) * (price.cacheRead ?? 0) + Double(usage.cacheWrite) * (price.cacheWrite ?? 0)
        return (perMillion / 1_000_000, estimated)
    }
}

extension ModelPriceList {
    /// A harness names `provider/model`; the list names the model alone.
    static func price(of model: String, in entries: [PriceListEntry]) -> ModelPrice? {
        let bare = model.firstIndex(of: "/").map { String(model[model.index(after: $0)...]) }
        return (entries.first { $0.id == model } ?? bare.flatMap { name in entries.first { $0.id == name } })?.price
    }
}
