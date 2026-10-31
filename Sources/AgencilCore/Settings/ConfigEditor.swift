import Foundation

/// A sheet or scalar refusal: a message per field name, `form` for a problem no field explains.
public struct SheetProblems: Error, Equatable, Sendable {
    public let fields: [String: String]

    public init(fields: [String: String]) { self.fields = fields }

    static func form(_ message: String) -> SheetProblems { SheetProblems(fields: ["form": message]) }
}

public struct SeatDraft: Sendable {
    public var name: String
    public var harness: String
    public var model: String
    public var endpoint: String?
    public var pin: String?
    public var capSeconds: Int?

    public init(name: String, harness: String, model: String, endpoint: String? = nil, pin: String? = nil, capSeconds: Int? = nil) {
        self.name = name
        self.harness = harness
        self.model = model
        self.endpoint = endpoint
        self.pin = pin
        self.capSeconds = capSeconds
    }
}

public struct CouncilDraft: Sendable {
    public var name: String
    public var seats: [String]
    public var rule: String
    public var quorum: Int?

    public init(name: String, seats: [String], rule: String, quorum: Int? = nil) {
        self.name = name
        self.seats = seats
        self.rule = rule
        self.quorum = quorum
    }
}

public struct RouteDraft: Sendable {
    public var callers: [String]
    public var target: String
    public var hopLimit: Int?

    public init(callers: [String], target: String, hopLimit: Int? = nil) {
        self.callers = callers
        self.target = target
        self.hopLimit = hopLimit
    }
}

/// Writes what the Settings sheets and switches change (docs/U9-SPEC.md "ConfigEditor"). Every call re-reads the
/// config, validates the whole result and writes once, so a refused call leaves the file as it was.
public struct ConfigEditor: Sendable {
    private static let looks: Set<String> = ["agencil", "solidGlass", "solidGlassLight"]
    private static let name = #"\A[a-z0-9][a-z0-9-]{0,39}\z"#
    private static let rules: Set<String> = ["any_blocker", "unanimous", "majority"]

    private let store: ConfigStore
    private let beforeUpdate: (@Sendable () throws -> Void)?

    /// `beforeUpdate` runs after the read and validation and before the write: the seam for a writer that gets in between.
    public init(directory: URL, beforeUpdate: (@Sendable () throws -> Void)? = nil) {
        store = ConfigStore(directory: directory)
        self.beforeUpdate = beforeUpdate
    }

    // MARK: objects

    @discardableResult
    public func add(_ draft: SeatDraft) throws -> ConfigSnapshot {
        try edit("seats") { values, config in
            var problems: [String: String] = [:]
            if draft.name.range(of: Self.name, options: .regularExpression) == nil {
                problems["name"] = "1 to 40 characters of a-z, 0-9 and dashes"
            } else if Self.taken(draft.name, config) { problems["name"] = "that name is already used" }
            if !SeatConfig.harnesses.contains(draft.harness) { problems["harness"] = "pick one of the known harnesses" }
            if draft.model.isEmpty { problems["model"] = "a seat needs a model" }
            if let cap = draft.capSeconds, !(1...3600).contains(cap) { problems["capSeconds"] = "1 to 3600 seconds" }
            var object: [String: Any] = ["name": draft.name, "harness": draft.harness, "model": draft.model]
            if let endpoint = draft.endpoint, !endpoint.isEmpty { object["endpoint"] = endpoint }
            if let pin = draft.pin, !pin.isEmpty { object["pin"] = pin }
            if let cap = draft.capSeconds { object["cap"] = ["seconds": cap] }
            return (problems, object)
        }
    }

    @discardableResult
    public func add(_ draft: CouncilDraft) throws -> ConfigSnapshot {
        try edit("councils") { values, config in
            var problems: [String: String] = [:]
            if draft.name.range(of: Self.name, options: .regularExpression) == nil {
                problems["name"] = "1 to 40 characters of a-z, 0-9 and dashes"
            } else if Self.taken(draft.name, config) { problems["name"] = "that name is already used" }
            if draft.seats.isEmpty { problems["seats"] = "a council needs seats" }
            else if let unknown = draft.seats.first(where: { config.seat(named: $0) == nil }) { problems["seats"] = "\(unknown) is not a seat" }
            if !Self.rules.contains(draft.rule) { problems["rule"] = "any_blocker, unanimous or majority" }
            if let quorum = draft.quorum, !(1...max(draft.seats.count, 1)).contains(quorum) || draft.seats.isEmpty {
                problems["quorum"] = "1 to the number of seats"
            }
            var object: [String: Any] = ["name": draft.name, "seats": draft.seats, "rule": draft.rule]
            if let quorum = draft.quorum { object["quorum"] = quorum }
            return (problems, object)
        }
    }

    @discardableResult
    public func add(_ draft: RouteDraft) throws -> ConfigSnapshot {
        try edit("routes") { values, config in
            var problems: [String: String] = [:]
            if draft.callers.isEmpty || draft.callers.contains(where: \.isEmpty) { problems["callers"] = "a route needs callers" }
            if draft.target.isEmpty { problems["target"] = "a route needs a target" }
            else if config.seat(named: config.resolveName(draft.target)) == nil, !config.councils.contains(where: { $0.name == draft.target }) {
                problems["target"] = "the target is not a seat, an alias or a council"
            }
            if let hops = draft.hopLimit, !(1...4).contains(hops) { problems["hopLimit"] = "1 to 4" }
            var object: [String: Any] = ["callers": draft.callers, "target": draft.target]
            if let hops = draft.hopLimit { object["hop_limit"] = hops }
            return (problems, object)
        }
    }

    // MARK: scalars

    /// A scalar the panes save as it changes. The same value writes nothing.
    @discardableResult
    public func set(_ key: String, _ value: String) throws -> ConfigSnapshot {
        try change(key) { _ in value }
    }

    /// Turns one notification kind on or off inside the snapshot the write is checked against, so another writer's
    /// change to the list is never overwritten from a cached copy.
    @discardableResult
    public func setNotify(_ kind: String, on: Bool) throws -> ConfigSnapshot {
        try change("notify") { current in
            var kinds = Set(NotifySettings.kinds)
            if let current, let list = (try? JSONSerialization.jsonObject(with: Data(current.utf8))) as? [String] { kinds = Set(list) }
            if on { kinds.insert(kind) } else { kinds.remove(kind) }
            return Self.json(kinds.sorted())
        }
    }

    /// Sets one field of the `limits` object, keeping the others as the file holds them now.
    @discardableResult
    public func setLimit(_ field: String, _ value: Int) throws -> ConfigSnapshot {
        try change("limits") { current in
            var limits = current.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
            limits[field] = value
            return Self.json(limits)
        }
    }

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func change(_ key: String, _ transform: (String?) -> String) throws -> ConfigSnapshot {
        let snapshot = try read()
        guard ["look", "notify", "limits", "agent_access"].contains(key) else { throw SheetProblems(fields: [key: "this setting is not editable here"]) }
        let value = transform(snapshot.values[key])
        if key == "look", !Self.looks.contains(value) { throw SheetProblems(fields: [key: "pick one of the three looks"]) }
        if key == "agent_access", !["on", "off"].contains(value) { throw SheetProblems(fields: [key: "on or off"]) }
        var next = snapshot.values
        next[key] = value
        do { _ = try SeatConfig(values: next) } catch let problem as ConfigProblem { throw SheetProblems(fields: [key: problem.problem]) }
        if snapshot.values[key] == value { return snapshot }
        return try write(snapshot, key: key, text: value)
    }

    // MARK: shared

    private func read() throws -> ConfigSnapshot {
        do { return try store.read() } catch { throw SheetProblems.form(error.localizedDescription) }
    }

    private static func taken(_ name: String, _ config: SeatConfig) -> Bool {
        config.seat(named: name) != nil || config.aliases[name] != nil || config.councils.contains { $0.name == name }
    }

    /// Reads, checks the draft's fields, appends its object to `key`'s array and validates the whole config.
    private func edit(_ key: String,
                      _ build: ([String: String], SeatConfig) -> (problems: [String: String], object: [String: Any])) throws -> ConfigSnapshot {
        let snapshot = try read()
        let config: SeatConfig
        do { config = try SeatConfig(values: snapshot.values) } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
        let (problems, object) = build(snapshot.values, config)
        guard problems.isEmpty else { throw SheetProblems(fields: problems) }
        var list = try SeatConfig.array(snapshot.values[key], key)
        list.append(object)
        let data = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        var next = snapshot.values
        next[key] = text
        do { _ = try SeatConfig(values: next) } catch let problem as ConfigProblem { throw SheetProblems.form(problem.message) }
        return try write(snapshot, key: key, text: text)
    }

    private func write(_ snapshot: ConfigSnapshot, key: String, text: String) throws -> ConfigSnapshot {
        do {
            try beforeUpdate?()
            return try store.update(expectedRevision: snapshot.revision) { $0[key] = text }
        } catch {
            throw SheetProblems.form(error.localizedDescription)
        }
    }
}
