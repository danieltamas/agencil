import Foundation

/// Dollars per million tokens.
public struct Price: Equatable, Sendable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public static let free = Price(inputPerMillion: 0, outputPerMillion: 0)
}

/// A spending limit on a route, a chain root or a vendor.
public struct Budget: Equatable, Sendable {
    public enum Scope: String, Sendable { case route, root, vendor }
    public enum Window: String, Sendable { case run, week, lifetime }
    public let name: String
    public let scope: Scope
    public let key: String
    public let window: Window
    public let dollars: Double?
    public let tokens: Int?
    public let hard: Bool
}

/// Capacity limits; defaults apply to anything not set.
public struct Limits: Equatable, Sendable {
    public var seatsAtOnce = 4
    public var processCap = 8
    public var memoryFloorMB = 0
}

extension SeatConfig {
    static func parsePrice(_ value: Any?, seat: String) throws -> Price? {
        guard let value else { return nil }
        guard let object = value as? [String: Any], Set(object.keys) == ["input_per_mtok", "output_per_mtok"],
              let input = number(object["input_per_mtok"]), let output = number(object["output_per_mtok"]),
              input >= 0, output >= 0, input <= 100_000, output <= 100_000 else { throw ConfigProblem(key: "seats", problem: "seat \(seat) has a bad price") }
        return Price(inputPerMillion: input, outputPerMillion: output)
    }

    /// A finite JSON number; booleans and text are not numbers here.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func parseBudgets(_ text: String?) throws -> [Budget] {
        var seen = Set<String>()
        return try array(text, "budgets").map { item in
            func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "budgets", problem: problem) }
            guard let name = item["name"] as? String, !name.isEmpty else { throw fail("a budget needs a name") }
            guard seen.insert(name).inserted else { throw fail("budget \(name) is listed twice") }
            guard let scope = (item["scope"] as? String).flatMap(Budget.Scope.init) else { throw fail("budget \(name) has an unknown scope") }
            guard let key = item["key"] as? String, !key.isEmpty else { throw fail("budget \(name) needs a key") }
            guard let window = (item["window"] as? String).flatMap(Budget.Window.init) else { throw fail("budget \(name) has an unknown window") }
            if let dollars = item["dollars"], number(dollars).map({ $0 >= 0 }) != true { throw fail("budget \(name) has bad dollars") }
            if let tokens = item["tokens"], whole(tokens).map({ (0...1_000_000_000_000_000).contains($0) }) != true { throw fail("budget \(name) has bad tokens") }
            if let hard = item["hard"], !(hard is Bool) { throw fail("budget \(name) has a bad hard flag") }
            let dollars = number(item["dollars"]), tokens = whole(item["tokens"])
            guard dollars != nil || tokens != nil else { throw fail("budget \(name) needs dollars or tokens") }
            return Budget(name: name, scope: scope, key: key, window: window, dollars: dollars, tokens: tokens,
                          hard: item["hard"] as? Bool ?? false)
        }
    }

    static func parseLimits(_ text: String?) throws -> Limits {
        guard let text, !text.isEmpty else { return Limits() }
        func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "limits", problem: problem) }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { throw fail("not valid JSON") }
        guard let object = parsed as? [String: Any] else { throw fail("expected an object") }
        var limits = Limits()
        for (key, value) in object {
            guard let number = whole(value) else { throw fail("\(key) must be a whole number") }
            switch key {
            case "seats_at_once":
                guard (1...16).contains(number) else { throw fail("seats_at_once is 1 to 16") }
                limits.seatsAtOnce = number
            case "process_cap": limits.processCap = number
            case "memory_floor_mb":
                guard number >= 0 else { throw fail("memory_floor_mb cannot be negative") }
                limits.memoryFloorMB = number
            default: throw fail("unknown limit \(key)")
            }
        }
        if object["process_cap"] == nil { limits.processCap = limits.seatsAtOnce + 4 }
        guard limits.processCap >= limits.seatsAtOnce else { throw fail("process_cap is below seats_at_once") }
        return limits
    }
}
