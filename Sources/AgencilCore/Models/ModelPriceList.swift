import Foundation

/// USD per million tokens. Cache prices are absent when the list has none: never filled in from the input price.
public struct ModelPrice: Equatable, Codable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double?
    public let cacheWrite: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// One model of the public price list, with its price or none.
public struct PriceListEntry: Equatable, Codable, Sendable {
    public let id: String
    public let provider: String
    public let price: ModelPrice?

    public init(id: String, provider: String, price: ModelPrice?) {
        self.id = id
        self.provider = provider
        self.price = price
    }
}

/// LiteLLM's public price list: every provider, one JSON file that tracks the vendors' pricing pages. Read here
/// into plain entries; a download that looks broken is refused so the cached list stays.
public enum ModelPriceList {
    public static let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    public static let source = "LiteLLM price list"
    public static let refreshEvery: TimeInterval = 86_400
    private static let downloadLimit = 32 * 1024 * 1024
    private static let ceiling = 10_000.0
    private static let chatModes: Set<String> = ["chat", "completion", "responses"]

    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case implausible(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): "The price list could not be read: \(detail)"
            case .implausible(let detail): "The price list looks wrong, so the old one stays: \(detail)"
            }
        }
    }

    /// Chat-capable models only. A price needs both token prices; one that is present but invalid (negative, not a
    /// number, absurdly large) leaves the model without a price rather than with a guessed one.
    public static func parse(_ data: Data) throws -> [PriceListEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable("not a JSON object")
        }
        var entries: [PriceListEntry] = []
        for (id, value) in root {
            guard id != "sample_spec", id.count <= 160, id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let item = value as? [String: Any], let provider = item["litellm_provider"] as? String,
                  chatModes.contains(item["mode"] as? String ?? "") else { continue }
            entries.append(PriceListEntry(id: id, provider: provider, price: price(item)))
        }
        entries.sort { $0.id < $1.id }
        try checkPlausible(entries)
        return entries
    }

    public static func fetch(session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.unreadable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard data.count <= downloadLimit else { throw Failure.unreadable("the download is too large") }
        return data
    }

    /// A list that lost half its models since the one cached is a broken download.
    static func checkContinuity(_ fresh: [PriceListEntry], against cached: [PriceListEntry]) throws {
        if fresh.count * 2 < cached.count { throw Failure.implausible("\(fresh.count) models, down from \(cached.count)") }
    }

    public static func isStale(updatedAt: Date?, now: Date) -> Bool {
        updatedAt.map { now.timeIntervalSince($0) >= refreshEvery } ?? true
    }

    private static func checkPlausible(_ entries: [PriceListEntry]) throws {
        let priced = entries.filter { $0.price != nil }
        guard entries.count >= 50, priced.count >= 20, entries.contains(where: { $0.id.hasPrefix("claude-") }) else {
            throw Failure.implausible("\(entries.count) models")
        }
    }

    private static func price(_ item: [String: Any]) -> ModelPrice? {
        guard let input = perMillion(item["input_cost_per_token"]), let output = perMillion(item["output_cost_per_token"]) else { return nil }
        var cache: [Double?] = []
        for key in ["cache_read_input_token_cost", "cache_creation_input_token_cost"] {
            guard item[key] != nil else { cache.append(nil); continue }
            guard let cost = perMillion(item[key]) else { return nil }
            cache.append(cost)
        }
        return ModelPrice(input: input, output: output, cacheRead: cache[0], cacheWrite: cache[1])
    }

    private static func perMillion(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        // Six decimals absorb the float noise of 2.5e-07 x 1e6.
        let perMillion = (number.doubleValue * 1_000_000 * 1_000_000).rounded() / 1_000_000
        return perMillion <= ceiling ? perMillion : nil
    }
}
