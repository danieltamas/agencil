import Foundation

/// What the Costs pane groups by (docs/U31-SPEC.md).
public enum CostGroup: String, CaseIterable, Sendable { case project, council, seat, model, caller }

/// The answered seat calls of one local day and one project, council, seat, model and caller.
public struct CostRow: Hashable, Sendable {
    /// `YYYY-MM-DD` in the machine's local calendar.
    public let day: String
    public let project, council, seat, model, caller: String
    public let calls: Int
    /// Calls that answered and carry no cost: counted, never priced, so a total never hides a guess.
    public let unpriced: Int
    public let cost: Decimal

    public init(day: String, project: String, council: String, seat: String, model: String, caller: String,
                calls: Int, unpriced: Int, cost: Decimal) {
        self.day = day
        self.project = project
        self.council = council
        self.seat = seat
        self.model = model
        self.caller = caller
        self.calls = calls
        self.unpriced = unpriced
        self.cost = cost
    }
}

/// One answered seat call of a day, for the day's list.
public struct CostEntry: Hashable, Sendable {
    public let thread: String
    public let sitting: String?
    public let seat, model, caller, project, council: String
    public let cost: Decimal?
    public let tokensIn, tokensOut: Int?
    public let at: String
}

/// This Mac's seat spend read the way Bton reads its costs: days, groups over a window, months.
public struct CostReport: Sendable {
    public struct Day: Hashable, Sendable {
        public let date: Date
        public let cost: Decimal
        public let calls: Int
        public let unpriced: Int
    }

    public struct GroupRow: Hashable, Sendable {
        public let name: String
        public let calls: Int
        public let unpriced: Int
        public let cost: Decimal
    }

    public struct Month: Hashable, Sendable {
        public let month: String
        public let total: Decimal
        public let unpriced: Int
        public let projects: [GroupRow]
    }

    public struct Unreadable: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    public let now: Date
    let calendar: Calendar
    let rows: [CostRow]

    public init(rows: [CostRow], now: Date = .now, calendar: Calendar = .current) {
        self.rows = rows
        self.now = now
        self.calendar = calendar
    }

    /// The `costs` op's data object; anything that does not read whole is refused, so a half-read ledger never shows as a total.
    public init(json: [String: Any], calendar: Calendar = .current) throws {
        guard let stamp = json["now"] as? String, let now = ISO8601DateFormatter().date(from: stamp) else {
            throw Unreadable(reason: "the costs reply had no readable time")
        }
        guard let list = json["rows"] as? [[String: Any]] else { throw Unreadable(reason: "the costs reply had no rows") }
        var rows: [CostRow] = []
        for item in list {
            guard let day = item["day"] as? String, let calls = item["calls"] as? Int, let unpriced = item["unpriced"] as? Int,
                  let cost = Self.money(item["cost"]) else { throw Unreadable(reason: "a costs row was unreadable") }
            func name(_ key: String) -> String { item[key] as? String ?? "unknown" }
            rows.append(CostRow(day: day, project: name("project"), council: name("council"), seat: name("seat"), model: name("model"),
                                caller: name("caller"), calls: calls, unpriced: unpriced, cost: cost))
        }
        self.init(rows: rows, now: now, calendar: calendar)
    }

    /// The day's list out of a `costs` reply with a `day`; an entry that does not read is left out.
    public static func entries(json: [String: Any]) -> [CostEntry] { (try? checkedEntries(json: json)) ?? [] }

    /// The same list, but a reply that does not read whole is refused: an empty list must mean an empty day.
    public static func checkedEntries(json: [String: Any]) throws -> [CostEntry] {
        guard let list = json["entries"] as? [[String: Any]] else { throw Unreadable(reason: "the costs reply had no entries") }
        return try list.map { item in
            guard let thread = item["thread"] as? String, let at = item["at"] as? String else { throw Unreadable(reason: "a costs entry was unreadable") }
            func name(_ key: String) -> String { item[key] as? String ?? "unknown" }
            return CostEntry(thread: thread, sitting: item["sitting"] as? String, seat: name("seat"), model: name("model"),
                             caller: name("caller"), project: name("project"), council: name("council"), cost: money(item["cost"]),
                             tokensIn: item["tokens_in"] as? Int, tokensOut: item["tokens_out"] as? Int, at: at)
        }
    }

    /// A JSON number as the shortest decimal that prints it, so 0.1 is 0.1 and not a binary neighbour.
    static func money(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Decimal(string: "\(number.doubleValue)")
    }

    /// One entry per calendar day, the last `n` ending today, zeros where nothing ran.
    public func days(last n: Int) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var totals: [String: (cost: Decimal, calls: Int, unpriced: Int)] = [:]
        for row in rows {
            var entry = totals[row.day] ?? (0, 0, 0)
            entry.cost += row.cost
            entry.calls += row.calls
            entry.unpriced += row.unpriced
            totals[row.day] = entry
        }
        return (0..<max(n, 0)).reversed().compactMap { back -> Day? in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let mine = totals[Self.day(of: date, calendar: calendar)] ?? (0, 0, 0)
            return Day(date: date, cost: mine.cost, calls: mine.calls, unpriced: mine.unpriced)
        }
    }

    /// The calls of the days in `from..<to`, grouped, dearest first.
    public func rows(by group: CostGroup, from: Date, to: Date) -> [GroupRow] {
        let start = calendar.startOfDay(for: from)
        return Self.grouped(rows.filter { row in
            guard let date = date(ofDay: row.day) else { return false }
            return date >= start && date < to
        }, by: group)
    }

    /// Every month, newest first, with its projects.
    public func months() -> [Month] {
        Dictionary(grouping: rows) { String($0.day.prefix(7)) }
            .map { month, rows in
                Month(month: month, total: rows.reduce(0) { $0 + $1.cost }, unpriced: rows.reduce(0) { $0 + $1.unpriced },
                      projects: Self.grouped(rows, by: .project))
            }
            .sorted { $0.month > $1.month }
    }

    /// `YYYY-MM-DD` of a moment in `calendar`.
    public static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func grouped(_ rows: [CostRow], by group: CostGroup) -> [GroupRow] {
        var totals: [String: (calls: Int, unpriced: Int, cost: Decimal)] = [:]
        for row in rows {
            let name: String = switch group {
            case .project: row.project
            case .council: row.council
            case .seat: row.seat
            case .model: row.model
            case .caller: row.caller
            }
            var entry = totals[name] ?? (0, 0, 0)
            entry.calls += row.calls
            entry.unpriced += row.unpriced
            entry.cost += row.cost
            totals[name] = entry
        }
        return totals.map { GroupRow(name: $0.key, calls: $0.value.calls, unpriced: $0.value.unpriced, cost: $0.value.cost) }
            .sorted { ($0.cost, $0.calls, $1.name) > ($1.cost, $1.calls, $0.name) }
    }
}
