import Foundation

/// A sheet or scalar refusal: a message per field name, `form` for a problem no field explains.
public struct SheetProblems: Error, Equatable, Sendable {
    public let fields: [String: String]

    public init(fields: [String: String]) { self.fields = fields }

    static func form(_ message: String) -> SheetProblems { SheetProblems(fields: ["form": message]) }
}

public struct SeatDraft: Equatable, Sendable {
    public var name: String
    public var harness: String
    public var model: String
    public var endpoint: String?
    public var pin: String?
    public var capSeconds: Int?
    /// Set by a preset (docs/U25-SPEC.md); absent, the config's own defaults apply.
    public var vendor: String?
    public var plan: String?
    public var hosted: Bool?
    /// finder, skeptic, synthesizer or answerer; absent, the seat answers.
    public var role: String?

    public init(name: String, harness: String, model: String, endpoint: String? = nil, pin: String? = nil, capSeconds: Int? = nil,
                vendor: String? = nil, plan: String? = nil, hosted: Bool? = nil, role: String? = nil) {
        self.name = name
        self.harness = harness
        self.model = model
        self.endpoint = endpoint
        self.pin = pin
        self.capSeconds = capSeconds
        self.vendor = vendor
        self.plan = plan
        self.hosted = hosted
        self.role = role
    }
}

public struct CouncilDraft: Equatable, Sendable {
    public var name: String
    public var seats: [String]
    public var rule: String
    public var quorum: Int?
    /// Seats called in when a sitting loses one; never also in `seats`.
    public var spare: [String]
    /// Seats that write the closing summary; never also in `seats` or `spare`.
    public var synthesizer: [String]

    public init(name: String, seats: [String], rule: String, quorum: Int? = nil, spare: [String] = [], synthesizer: [String] = []) {
        self.name = name
        self.seats = seats
        self.rule = rule
        self.quorum = quorum
        self.spare = spare
        self.synthesizer = synthesizer
    }
}

public struct RouteDraft: Equatable, Sendable {
    public var callers: [String]
    public var target: String
    public var hopLimit: Int?
    /// The keys the sheet has no field for. They are read so that `was` is the complete route, and an update keeps them.
    public var residency: String?
    public var requires: [String]
    public var fallbacks: [String]

    public init(callers: [String], target: String, hopLimit: Int? = nil, residency: String? = nil, requires: [String] = [],
                fallbacks: [String] = []) {
        self.callers = callers
        self.target = target
        self.hopLimit = hopLimit
        self.residency = residency
        self.requires = requires
        self.fallbacks = fallbacks
    }
}

/// Writes what the Settings sheets and switches change (docs/U9-SPEC.md "ConfigEditor"). Every call re-reads the
/// config, validates the whole result and writes once, so a refused call leaves the file as it was.
public struct ConfigEditor: Sendable {
    private static let looks: Set<String> = ["agencil", "solidGlass", "solidGlassLight"]
    static let name = #"\A[a-z0-9][a-z0-9-]{0,39}\z"#
    static let rules: Set<String> = ["any_blocker", "unanimous", "majority"]

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
        try rewrite("seats") { list, config in
            let problems = Self.problems(draft, config, replacing: nil)
            if problems.isEmpty { list.append(Self.object(draft, over: [:])) }
            return problems
        }
    }

    @discardableResult
    public func add(_ draft: CouncilDraft) throws -> ConfigSnapshot {
        try rewrite("councils") { list, config in
            let problems = Self.problems(draft, config, replacing: nil)
            if problems.isEmpty { list.append(Self.object(draft, over: [:])) }
            return problems
        }
    }

    @discardableResult
    public func add(_ draft: RouteDraft) throws -> ConfigSnapshot {
        try rewrite("routes") { list, config in
            let problems = Self.problems(draft, config)
            if problems.isEmpty { list.append(Self.object(draft, over: [:])) }
            return problems
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

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func change(_ key: String, _ transform: (String?) -> String) throws -> ConfigSnapshot {
        let snapshot = try read()
        guard ["look", "notify", "limits", "agent_access"].contains(key) || Self.paneKeys.contains(key) else { throw SheetProblems(fields: [key: "this setting is not editable here"]) }
        let value = transform(snapshot.values[key])
        if key == "look", !Self.looks.contains(value) { throw SheetProblems(fields: [key: "pick one of the three looks"]) }
        if key == "agent_access", !["on", "off"].contains(value) { throw SheetProblems(fields: [key: "on or off"]) }
        if let problem = Self.paneProblem(key, value) { throw SheetProblems(fields: [key: problem]) }
        var next = snapshot.values
        next[key] = value
        do { _ = try SeatConfig(values: next) } catch let problem as ConfigProblem { throw SheetProblems(fields: [key: problem.problem]) }
        if snapshot.values[key] == value { return snapshot }
        return try write(snapshot, key: key, text: value)
    }

    // MARK: shared

    func read() throws -> ConfigSnapshot {
        do { return try store.read() } catch { throw SheetProblems.form(error.localizedDescription) }
    }

    static func taken(_ name: String, _ config: SeatConfig) -> Bool {
        config.seat(named: name) != nil || config.aliases[name] != nil || config.councils.contains { $0.name == name }
    }

    /// Reads, lets `change` check the draft and edit `key`'s array (it returns the problems it found, none when it
    /// changed the list), validates the whole config and writes once.
    func rewrite(_ key: String, _ change: (inout [[String: Any]], SeatConfig) -> [String: String]) throws -> ConfigSnapshot {
        let snapshot = try read()
        let config: SeatConfig
        do { config = try SeatConfig(values: snapshot.values) } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
        var list = try SeatConfig.array(snapshot.values[key], key)
        let problems = change(&list, config)
        guard problems.isEmpty else { throw SheetProblems(fields: problems) }
        let data = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        var next = snapshot.values
        next[key] = text
        do { _ = try SeatConfig(values: next) } catch let problem as ConfigProblem { throw SheetProblems.form(problem.message) }
        return try write(snapshot, key: key, text: text)
    }

    func write(_ snapshot: ConfigSnapshot, key: String, text: String) throws -> ConfigSnapshot {
        do {
            try beforeUpdate?()
            return try store.update(expectedRevision: snapshot.revision) { $0[key] = text }
        } catch {
            throw SheetProblems.form(error.localizedDescription)
        }
    }
}
