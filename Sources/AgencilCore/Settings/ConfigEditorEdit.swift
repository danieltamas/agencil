import Foundation

/// What the sheets check and write for a seat, a council or a route; `add`, `update` and `remove` share it
/// (docs/U9-SPEC.md "Editing"). An update keeps the keys the sheet has no field for (price, rounds, fallbacks ...).
extension ConfigEditor {
    // MARK: update and remove

    /// Replaces seat `old` with `draft`. A rename that a council, route, budget or alias still names is refused. `was`, when
    /// given, is what the sheet opened with; a seat or council changed since is refused (the same holds for councils).
    @discardableResult
    public func update(seat old: String, was: SeatDraft? = nil, with draft: SeatDraft) throws -> ConfigSnapshot {
        try rewrite("seats") { list, config in
            guard let at = list.firstIndex(where: { $0["name"] as? String == old }) else { return .gone("seat \(old)") }
            if let was, Self.seatDraft(list[at]) != was { return .gone("seat \(old)") }
            var problems = Self.problems(draft, config, replacing: old)
            if draft.name != old, let uses = Self.uses(ofSeat: old, config) { problems["name"] = "\(uses); remove those uses before renaming" }
            if problems.isEmpty { list[at] = Self.object(draft, over: list[at]) }
            return problems
        }
    }

    /// Removes the seat from the file and from every council's seat list and spare list, in one write. Refused when the
    /// seat is a synthesizer, a route's target, fallback or caller, a route-scoped budget's key or an alias's seat, or when a
    /// council would be left with no seat.
    @discardableResult
    public func remove(seat name: String) throws -> ConfigSnapshot {
        let snapshot = try read()
        let config = try Self.config(snapshot)
        var seats = try SeatConfig.array(snapshot.values["seats"], "seats")
        guard let at = seats.firstIndex(where: { $0["name"] as? String == name }) else { throw SheetProblems(fields: .gone("seat \(name)")) }
        if let uses = Self.uses(ofSeat: name, config, includingMembership: false) { throw SheetProblems.form("\(uses); remove those uses first") }
        seats.remove(at: at)
        var councils = try SeatConfig.array(snapshot.values["councils"], "councils")
        for index in councils.indices {
            for key in ["seats", "spare"] {
                guard let members = councils[index][key] as? [String], members.contains(name) else { continue }
                let rest = members.filter { $0 != name }
                councils[index][key] = rest.isEmpty ? nil : rest
            }
            if councils[index]["seats"] == nil {
                throw SheetProblems.form("council \(councils[index]["name"] as? String ?? "") would be left with no seat; remove the council or add another seat first")
            }
        }
        var next = snapshot.values
        next["seats"] = Self.json(seats)
        next["councils"] = Self.json(councils)
        do { _ = try SeatConfig(values: next) } catch let problem as ConfigProblem { throw SheetProblems.form(problem.message) }
        return try write(snapshot, updates: ["seats": next["seats"] ?? "", "councils": next["councils"] ?? ""])
    }

    /// The councils whose seat list or spare list names `seat`: what removing it takes it out of.
    public func councils(holding seat: String) throws -> [String] {
        try Self.config(try read()).councils.filter { $0.seats.contains(seat) || $0.spares.contains(seat) }.map(\.name)
    }

    @discardableResult
    public func update(council old: String, was: CouncilDraft? = nil, with draft: CouncilDraft) throws -> ConfigSnapshot {
        try rewrite("councils") { list, config in
            guard let at = list.firstIndex(where: { $0["name"] as? String == old }) else { return .gone("council \(old)") }
            if let was, Self.councilDraft(list[at]) != was { return .gone("council \(old)") }
            var problems = Self.problems(draft, config, replacing: old)
            if draft.name != old, let uses = Self.uses(ofCouncil: old, config) { problems["name"] = "\(uses); remove those uses before renaming" }
            if problems.isEmpty { list[at] = Self.object(draft, over: list[at]) }
            return problems
        }
    }

    @discardableResult
    public func remove(council name: String) throws -> ConfigSnapshot {
        try rewrite("councils") { list, config in
            guard let at = list.firstIndex(where: { $0["name"] as? String == name }) else { return .gone("council \(name)") }
            if let uses = Self.uses(ofCouncil: name, config) { return ["form": "\(uses); remove those uses first"] }
            list.remove(at: at)
            return [:]
        }
    }

    /// A route has no name: it is the `index`th entry, and `was` must still be what sits there, so a file that
    /// changed since the list was shown is refused instead of editing a different route.
    @discardableResult
    public func update(routeAt index: Int, was: RouteDraft, with draft: RouteDraft) throws -> ConfigSnapshot {
        try rewrite("routes") { list, config in
            guard Self.route(in: list, at: index) == was else { return .gone("route") }
            let problems = Self.problems(draft, config)
            if problems.isEmpty { list[index] = Self.object(draft, over: list[index]) }
            return problems
        }
    }

    @discardableResult
    public func remove(routeAt index: Int, was: RouteDraft) throws -> ConfigSnapshot {
        try rewrite("routes") { list, _ in
            guard Self.route(in: list, at: index) == was else { return .gone("route") }
            list.remove(at: index)
            return [:]
        }
    }

    // MARK: current drafts

    /// The seats, councils and routes as the file holds them now, for the sheets to open pre-filled.
    public func current() throws -> (seats: [SeatDraft], councils: [CouncilDraft], routes: [RouteDraft]) {
        try Self.drafts(in: try read().values)
    }

    /// The same from values already read, so a list shown and the drafts bound to it come from one read.
    public static func drafts(in values: [String: String]) throws -> (seats: [SeatDraft], councils: [CouncilDraft], routes: [RouteDraft]) {
        do {
            let seats = try SeatConfig.array(values["seats"], "seats").map(Self.seatDraft)
            let councils = try SeatConfig.array(values["councils"], "councils").map(Self.councilDraft)
            let routeItems = try SeatConfig.array(values["routes"], "routes")
            return (seats, councils, routeItems.indices.compactMap { Self.route(in: routeItems, at: $0) })
        } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
    }

    private static func seatDraft(_ item: [String: Any]) -> SeatDraft {
        SeatDraft(name: item["name"] as? String ?? "", harness: item["harness"] as? String ?? "", model: item["model"] as? String ?? "",
                  endpoint: item["endpoint"] as? String, pin: item["pin"] as? String,
                  capSeconds: SeatConfig.whole((item["cap"] as? [String: Any])?["seconds"]),
                  vendor: item["vendor"] as? String, plan: item["plan"] as? String, hosted: SeatConfig.flag(item["hosted"]),
                  role: item["role"] as? String)
    }

    private static func councilDraft(_ item: [String: Any]) -> CouncilDraft {
        let synthesizer = (item["synthesizer"] as? [String]) ?? (item["synthesizer"] as? String).map { [$0] } ?? []
        return CouncilDraft(name: item["name"] as? String ?? "", seats: item["seats"] as? [String] ?? [],
                            rule: item["rule"] as? String ?? "majority", quorum: SeatConfig.whole(item["quorum"]),
                            spare: item["spare"] as? [String] ?? [], synthesizer: synthesizer,
                            mode: item["mode"] as? String ?? "review")
    }

    private static func route(in list: [[String: Any]], at index: Int) -> RouteDraft? {
        guard list.indices.contains(index), let callers = list[index]["callers"] as? [String],
              let target = list[index]["target"] as? String else { return nil }
        return RouteDraft(callers: callers, target: target, hopLimit: SeatConfig.whole(list[index]["hop_limit"]),
                         residency: list[index]["residency"] as? String, requires: list[index]["requires"] as? [String] ?? [],
                         fallbacks: list[index]["fallbacks"] as? [String] ?? [])
    }

    // MARK: what still uses a name

    /// "seat x is used by council a (spare), alias b", or nil when nothing names it. A removal takes the seat out of the
    /// councils' seat and spare lists itself, so it passes `includingMembership: false`; a rename cannot.
    private static func uses(ofSeat name: String, _ config: SeatConfig, includingMembership: Bool = true) -> String? {
        var users: [String] = []
        for council in config.councils {
            if includingMembership, council.seats.contains(name) { users.append("council \(council.name) (seat)") }
            if includingMembership, council.spares.contains(name) { users.append("council \(council.name) (spare)") }
            if council.synthesizers.contains(name) { users.append("council \(council.name) (synthesizer)") }
        }
        for route in config.routes where route.target == name { users.append("route \(route.callers.joined(separator: ", ")) to \(name) (target)") }
        for route in config.routes where route.fallbacks.contains(name) { users.append("route \(route.callers.joined(separator: ", ")) to \(route.target) (fallback)") }
        for route in config.routes where route.callers.contains(name) { users.append("route \(route.callers.joined(separator: ", ")) to \(route.target) (caller)") }
        users += budgetUses(of: name, config)
        for (alias, seat) in config.aliases.sorted(by: { $0.key < $1.key }) where seat == name { users.append("alias \(alias)") }
        return users.isEmpty ? nil : "seat \(name) is used by \(users.joined(separator: ", "))"
    }

    /// A route-scoped budget is keyed by the seat or council a route reaches.
    private static func budgetUses(of name: String, _ config: SeatConfig) -> [String] {
        config.budgets.filter { $0.scope == .route && $0.key == name }.map { "budget \($0.name)" }
    }

    private static func uses(ofCouncil name: String, _ config: SeatConfig) -> String? {
        var users = config.triggers.filter { $0.council == name }.map { "trigger \($0.name)" }
        users += config.routes.filter { $0.target == name }.map { "route \($0.callers.joined(separator: ", ")) to \(name) (target)" }
        users += budgetUses(of: name, config)
        return users.isEmpty ? nil : "council \(name) is used by \(users.joined(separator: ", "))"
    }

    // MARK: field checks and objects

    private static func nameProblem(_ name: String, _ config: SeatConfig, replacing old: String?) -> String? {
        if name.range(of: Self.name, options: .regularExpression) == nil { return "1 to 40 characters of a-z, 0-9 and dashes" }
        if name != old, taken(name, config) { return "that name is already used" }
        return nil
    }

    static func problems(_ draft: SeatDraft, _ config: SeatConfig, replacing old: String?) -> [String: String] {
        var problems: [String: String] = [:]
        if let problem = nameProblem(draft.name, config, replacing: old) { problems["name"] = problem }
        if !SeatConfig.harnesses.contains(draft.harness) { problems["harness"] = "pick one of the known harnesses" }
        if draft.model.isEmpty { problems["model"] = "a seat needs a model" }
        if let cap = draft.capSeconds, !(1...3600).contains(cap) { problems["capSeconds"] = "1 to 3600 seconds" }
        if let role = draft.role, !role.isEmpty, !SeatConfig.roles.contains(role) { problems["role"] = "finder, skeptic, synthesizer or answerer" }
        if let plan = draft.plan, !plan.isEmpty, Seat.Plan(rawValue: plan) == nil { problems["plan"] = "subscription, credit, free or local" }
        return problems
    }

    static func problems(_ draft: CouncilDraft, _ config: SeatConfig, replacing old: String?) -> [String: String] {
        var problems: [String: String] = [:]
        if let problem = nameProblem(draft.name, config, replacing: old) { problems["name"] = problem }
        if draft.seats.isEmpty { problems["seats"] = "a council needs seats" }
        else if let unknown = draft.seats.first(where: { config.seat(named: $0) == nil }) { problems["seats"] = "\(unknown) is not a seat" }
        if !Self.rules.contains(draft.rule) { problems["rule"] = "any_blocker, unanimous or majority" }
        if Council.Mode(rawValue: draft.mode) == nil { problems["mode"] = "review or consult" }
        if let quorum = draft.quorum, !(1...max(draft.seats.count, 1)).contains(quorum) || draft.seats.isEmpty {
            problems["quorum"] = "1 to the number of seats"
        }
        if let unknown = draft.spare.first(where: { config.seat(named: $0) == nil }) { problems["spare"] = "\(unknown) is not a seat" }
        else if let both = draft.spare.first(where: draft.seats.contains) { problems["spare"] = "\(both) is already a seat of this council" }
        if let unknown = draft.synthesizer.first(where: { config.seat(named: $0) == nil }) { problems["synthesizer"] = "\(unknown) is not a seat" }
        else if let both = draft.synthesizer.first(where: { draft.seats.contains($0) || draft.spare.contains($0) }) {
            problems["synthesizer"] = "\(both) is already a seat or a spare of this council"
        }
        return problems
    }

    static func problems(_ draft: RouteDraft, _ config: SeatConfig) -> [String: String] {
        var problems: [String: String] = [:]
        if draft.callers.isEmpty || draft.callers.contains(where: \.isEmpty) { problems["callers"] = "a route needs callers" }
        if draft.target.isEmpty { problems["target"] = "a route needs a target" }
        else if config.seat(named: config.resolveName(draft.target)) == nil, !config.councils.contains(where: { $0.name == draft.target }) {
            problems["target"] = "the target is not a seat, an alias or a council"
        }
        if let hops = draft.hopLimit, !(1...4).contains(hops) { problems["hopLimit"] = "1 to 4" }
        return problems
    }

    /// `existing` supplies the keys the draft has no field for; an empty field removes its key.
    static func object(_ draft: SeatDraft, over existing: [String: Any]) -> [String: Any] {
        var object = existing
        for key in ["endpoint", "pin", "vendor", "plan", "hosted", "role"] { object[key] = nil }
        object["name"] = draft.name
        object["harness"] = draft.harness
        object["model"] = draft.model
        for (key, text) in [("endpoint", draft.endpoint), ("pin", draft.pin), ("vendor", draft.vendor), ("plan", draft.plan), ("role", draft.role)] {
            if let text, !text.isEmpty { object[key] = text }
        }
        if let hosted = draft.hosted { object["hosted"] = hosted }
        var cap = existing["cap"] as? [String: Any] ?? [:]
        cap["seconds"] = nil
        if let seconds = draft.capSeconds { cap["seconds"] = seconds }
        object["cap"] = cap.isEmpty ? nil : cap
        return object
    }

    static func object(_ draft: CouncilDraft, over existing: [String: Any]) -> [String: Any] {
        var object = existing
        for key in ["spare", "synthesizer", "quorum", "mode"] { object[key] = nil }
        object["name"] = draft.name
        object["seats"] = draft.seats
        object["rule"] = draft.rule
        // review is the default, so a review council keeps the file as it was before modes existed.
        if draft.mode == Council.Mode.consult.rawValue { object["mode"] = draft.mode }
        if let quorum = draft.quorum { object["quorum"] = quorum }
        if !draft.spare.isEmpty { object["spare"] = draft.spare }
        if !draft.synthesizer.isEmpty { object["synthesizer"] = draft.synthesizer }
        return object
    }

    static func object(_ draft: RouteDraft, over existing: [String: Any]) -> [String: Any] {
        var object = existing
        object["hop_limit"] = nil
        object["callers"] = draft.callers
        object["target"] = draft.target
        if let hops = draft.hopLimit { object["hop_limit"] = hops }
        return object
    }
}

private extension Dictionary where Key == String, Value == String {
    /// The entry a sheet opened was removed or changed by someone else meanwhile.
    static func gone(_ what: String) -> [String: String] { ["form": "\(what) changed in the file; close this sheet and open it again"] }
}
