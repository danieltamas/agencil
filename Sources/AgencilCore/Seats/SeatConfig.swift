import Foundation

/// A named, owner-configured target: a harness kind and a model, with the limits of one call.
public struct Seat: Equatable, Sendable {
    public let name: String
    public let harness: String
    public let model: String
    public let endpoint: String?
    public let pin: String?
    public let role: String
    public let hardening: [String]
    public let capSeconds: Int
    public let capTokens: Int?
    public let price: Price
    /// Whether the seat's model runs on someone else's machine: what it is shown leaves this Mac.
    public var hosted = true
    /// Who trained the model: recusal and the independence flags compare vendors, never harnesses.
    public var vendor = ""
    /// How the seat is paid for (docs/U25-SPEC.md "Plans"): a free seat never counts against a dollar budget.
    public var plan: Plan = .credit

    public enum Plan: String, Sendable, CaseIterable {
        case subscription, credit, free, local

        /// The plan a seat has when config names none.
        static func inferred(harness: String, model: String) -> Plan {
            switch harness {
            case "claude", "codex": .subscription
            case "opencode": model.hasSuffix("-free") ? .free : .credit
            case "ollama": .local
            default: .credit
            }
        }
    }
}

/// Who may reach what: callers (ids or `any`), a target (seat, council or alias) and its limits.
public struct Route: Equatable, Sendable {
    public let callers: [String]
    public let target: String
    public let hopLimit: Int
    public let fallbacks: [String]
    /// A local-only route never reaches a hosted seat.
    public var localOnly = false
    /// Policies every seat on this route must enforce.
    public var requires: Set<Policy> = []
}

/// One of the config collections does not validate; every ask fails closed with this text.
public struct ConfigProblem: Error, Equatable, Sendable {
    public let key: String
    public let problem: String
    public var message: String { "failed: config \(key) is invalid: \(problem)" }
}

/// `seats`, `routes` and `aliases` from config.json, each one JSON text, validated as a whole.
public struct SeatConfig: Sendable {
    public static let harnesses: Set<String> = ["claude", "codex", "opencode", "hermes", "gemini", "aider", "goose", "ollama"]
    private static let roles: Set<String> = ["finder", "skeptic", "synthesizer", "answerer"]

    public let seats: [Seat]
    public let routes: [Route]
    public let aliases: [String: String]
    public let budgets: [Budget]
    public let limits: Limits
    public let councils: [Council]
    public let triggers: [Trigger]

    public init(values: [String: String]) throws {
        seats = try Self.parseSeats(values["seats"])
        let names = Set(seats.map(\.name))
        routes = try Self.parseRoutes(values["routes"], seatNames: names)
        aliases = try Self.parseAliases(values["aliases"], seatNames: names)
        councils = try Self.parseCouncils(values["councils"], seats: seats, aliases: aliases)
        triggers = try Self.parseTriggers(values["triggers"], councils: councils)
        _ = try NotifySettings(values: values)
        budgets = try Self.parseBudgets(values["budgets"])
        limits = try Self.parseLimits(values["limits"])
    }

    public func seat(named name: String) -> Seat? { seats.first { $0.name == name } }

    /// A seat name, or the seat an alias points at; anything else is unknown.
    public func resolveName(_ name: String) -> String { aliases[name] ?? name }

    /// The first route for `caller` to `target`: routes naming the caller come before `any`, in config order.
    public func route(from caller: String, to target: String) -> Route? { route(from: [caller], to: target) }

    /// `callers` lists the ways a caller is known, most specific first (a seat name, then its harness kind).
    public func route(from callers: [String], to target: String) -> Route? {
        let wanted = resolveName(target)
        let matching = routes.filter { resolveName($0.target) == wanted }
        for caller in callers {
            if let route = matching.first(where: { $0.callers.contains(caller) }) { return route }
        }
        return matching.first { $0.callers.contains("any") }
    }

    // MARK: parsing

    /// A JSON whole number; booleans, fractions and text are not numbers here.
    static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else { return nil }
        return number.intValue
    }

    /// A JSON true or false; the numbers 0 and 1 are not booleans here.
    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func array(_ text: String?, _ key: String) throws -> [[String: Any]] {
        guard let text, !text.isEmpty else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            throw ConfigProblem(key: key, problem: "not valid JSON")
        }
        guard let list = parsed as? [[String: Any]] else { throw ConfigProblem(key: key, problem: "expected a list of objects") }
        return list
    }

    private static func parseSeats(_ text: String?) throws -> [Seat] {
        var seen = Set<String>()
        return try array(text, "seats").map { item in
            func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "seats", problem: problem) }
            guard let name = item["name"] as? String,
                  name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
                throw fail("a seat name is 1 to 40 characters of a-z, 0-9 and dashes")
            }
            guard seen.insert(name).inserted else { throw fail("seat \(name) is listed twice") }
            guard let harness = item["harness"] as? String, harnesses.contains(harness) else {
                throw fail("seat \(name) has an unknown harness")
            }
            guard let model = item["model"] as? String, !model.isEmpty else { throw fail("seat \(name) needs a model") }
            if let role = item["role"], !(role is String) { throw fail("seat \(name) has a bad role") }
            let role = item["role"] as? String ?? "answerer"
            guard roles.contains(role) else { throw fail("seat \(name) has an unknown role") }
            if let pin = item["pin"], !(pin is String) { throw fail("seat \(name) has a bad pin") }
            if let endpoint = item["endpoint"], !(endpoint is String) { throw fail("seat \(name) has a bad endpoint") }
            if let hardening = item["hardening"], hardening as? [String] == nil { throw fail("seat \(name) has a bad hardening list") }
            if let cap = item["cap"], cap as? [String: Any] == nil { throw fail("seat \(name) has a bad cap") }
            let cap = item["cap"] as? [String: Any] ?? [:]
            guard let seconds = whole(cap["seconds"]) ?? (cap.isEmpty ? 120 : nil), (1...3600).contains(seconds) else {
                throw fail("seat \(name) needs cap.seconds from 1 to 3600")
            }
            if let tokens = cap["tokens"], !(whole(tokens).map { (1...10_000_000).contains($0) } ?? false) { throw fail("seat \(name) has a bad cap.tokens") }
            if let hosted = item["hosted"], Self.flag(hosted) == nil { throw fail("seat \(name) has a bad hosted flag") }
            let endpoint = item["endpoint"] as? String
            if let vendor = item["vendor"], vendor as? String == nil || (vendor as? String)?.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) == nil {
                throw fail("seat \(name) has a bad vendor")
            }
            var plan = Seat.Plan.inferred(harness: harness, model: model)
            if let stated = item["plan"] {
                guard let parsed = (stated as? String).flatMap(Seat.Plan.init) else { throw fail("seat \(name) has an unknown plan") }
                plan = parsed
            }
            let price = try parsePrice(item["price"], seat: name)
            if plan == .free, price != nil { throw fail("seat \(name) is free and has a price") }
            return Seat(name: name, harness: harness, model: model, endpoint: endpoint,
                        pin: item["pin"] as? String, role: role, hardening: item["hardening"] as? [String] ?? [],
                        capSeconds: seconds, capTokens: whole(cap["tokens"]),
                        price: price ?? .free,
                        hosted: Self.flag(item["hosted"]) ?? (harness != "ollama" || !isLoopback(endpoint)),
                        vendor: item["vendor"] as? String ?? vendor(of: harness), plan: plan)
        }
    }

    private static func parseRoutes(_ text: String?, seatNames: Set<String>) throws -> [Route] {
        try array(text, "routes").map { item in
            func fail(_ problem: String) -> ConfigProblem { ConfigProblem(key: "routes", problem: problem) }
            guard let callers = item["callers"] as? [String], !callers.isEmpty else { throw fail("a route needs callers") }
            guard let target = item["target"] as? String, !target.isEmpty else { throw fail("a route needs a target") }
            if let hops = item["hop_limit"], whole(hops) == nil { throw fail("hop_limit must be a whole number") }
            if let list = item["fallbacks"], list as? [String] == nil { throw fail("fallbacks must be a list of seat names") }
            let hops = whole(item["hop_limit"]) ?? 2
            guard (1...4).contains(hops) else { throw fail("hop_limit is 1 to 4") }
            let fallbacks = item["fallbacks"] as? [String] ?? []
            if let unknown = fallbacks.first(where: { !seatNames.contains($0) }) { throw fail("fallback \(unknown) is not a seat") }
            if let residency = item["residency"], !["any", "local"].contains(residency as? String ?? "") {
                throw fail("residency is any or local")
            }
            if let list = item["requires"], list as? [String] == nil { throw fail("requires must be a list of policy names") }
            var requires = Set<Policy>()
            for name in item["requires"] as? [String] ?? [] {
                guard let policy = Policy.named(name) else { throw fail("requires names an unknown policy: \(name)") }
                requires.insert(policy)
            }
            return Route(callers: callers, target: target, hopLimit: hops, fallbacks: fallbacks,
                         localOnly: item["residency"] as? String == "local", requires: requires)
        }
    }

    private static func isLoopback(_ endpoint: String?) -> Bool {
        guard let host = endpoint.flatMap({ URLComponents(string: $0)?.host })?.lowercased() else { return false }
        return ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
    }

    private static func parseAliases(_ text: String?, seatNames: Set<String>) throws -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            throw ConfigProblem(key: "aliases", problem: "not valid JSON")
        }
        guard let map = parsed as? [String: String] else { throw ConfigProblem(key: "aliases", problem: "expected an object of names") }
        for (alias, seat) in map where !seatNames.contains(seat) {
            throw ConfigProblem(key: "aliases", problem: "alias \(alias) points at \(seat), which is not a seat")
        }
        return map
    }
}

extension Seat {
    /// The same seat with its per-call cap shortened to `seconds`; an override never lengthens a configured cap.
    func capped(at seconds: Int) -> Seat {
        Seat(name: name, harness: harness, model: model, endpoint: endpoint, pin: pin, role: role, hardening: hardening,
             capSeconds: min(capSeconds, seconds), capTokens: capTokens, price: price, hosted: hosted, vendor: vendor, plan: plan)
    }
}
