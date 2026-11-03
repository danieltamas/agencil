import AgencilCore
import Foundation
import Testing
@testable import Agencil

func u31PageCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 7_200)!
    return calendar
}
func u31PageDate(_ day: String) -> Date {
    let numbers = day.split(separator: "-").map { Int($0)! }
    return u31PageCalendar().date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))!
}
func u31CostsJSON(day: String? = nil, longNames: Bool = false) -> [String: Any] {
    let name = longNames ? String(repeating: "harbor-checkout-", count: 4) : "harbor/checkout"
    func row(_ day: String, _ project: String, _ cost: Double, _ calls: Int, _ unpriced: Int) -> [String: Any] {
        ["day": day, "project": project, "council": "panel", "seat": "maya", "model": "harbor-model",
         "caller": "owner", "cost": cost, "calls": calls, "unpriced": unpriced]
    }
    var result: [String: Any] = ["now": "2030-03-14T23:30:00Z", "rows": [
        row("2030-03-15", name, 2.5, 2, 1), row("2030-03-14", "lumen/api", 1.25, 1, 0),
        row("2030-03-09", name, 4, 1, 0), row("2030-03-08", name, 8, 1, 0),
        row("2030-03-01", name, 16, 1, 0), row("2030-02-14", name, 32, 1, 0)]]
    if let day {
        result["entries"] = [["thread": "th_harbor", "sitting": "sit_harbor", "seat": "maya",
            "model": "harbor-model", "caller": "owner", "project": name, "council": "panel",
            "tokens_in": 8, "tokens_out": 4, "at": day + "T10:00:00Z"]]
    }
    return result
}

@Suite(.serialized) @MainActor struct U31CostsPageTests {
    // A8: JSON mapping and every range boundary use the reply's fixed now.
    @Test func reportRangesGroupsAndTotalsMapFromReadOnlyReply() async throws {
        let store = CostsStore(reader: { day in u31CostsJSON(day: day) }, calendar: u31PageCalendar())
        await store.reload()
        let report = try #require(store.report)
        #expect(report.days(last: 30).count == 30 && store.problem == nil)
        for (range, from, total) in [
            (CostsStore.Range.today, "2030-03-15", Decimal(string: "2.5")!),
            (.week, "2030-03-09", Decimal(string: "7.75")!),
            (.month, "2030-02-14", Decimal(string: "63.75")!),
            (.thisMonth, "2030-03-01", Decimal(string: "31.75")!)] {
            store.range = range
            #expect(store.window.from == u31PageDate(from))
            #expect(store.window.to == u31PageDate("2030-03-16"))
            for group in CostGroup.allCases {
                store.group = group
                #expect(store.groupTotal == total)
                #expect(store.groupRows.reduce(Decimal.zero) { $0 + $1.cost } == total)
                #expect(store.groupRows.reduce(0) { $0 + $1.unpriced } == 1)
            }
        }
        store.range = .week; store.group = .project
        #expect(store.groupRows.map(\.name) == ["harbor/checkout", "lumen/api"])
        #expect(store.groupRows.map(\.cost) == [Decimal(string: "6.5")!, Decimal(string: "1.25")!])
        #expect(store.groupRows.map(\.calls) == [3, 1])
    }

    // A8: only external reader I/O is substituted. A wrong requested day cannot pass.
    @Test func selectionFetchesLocalDayEntriesAndClearsOnAllDays() async throws {
        let store = CostsStore(reader: { day in
            if let day {
                #expect(day == "2030-03-15")
                return u31CostsJSON(day: day)
            }
            return u31CostsJSON()
        }, calendar: u31PageCalendar())
        await store.reload()
        await store.select(u31PageDate("2030-03-15"))
        #expect(store.selectedDay == u31PageDate("2030-03-15"))
        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1 && entry.thread == "th_harbor" && entry.sitting == "sit_harbor")
        #expect(entry.cost == nil && entry.tokensIn == 8 && entry.tokensOut == 4)
        #expect(entry.project == "harbor/checkout" && entry.council == "panel")
        await store.select(nil)
        #expect(store.selectedDay == nil && store.entries.isEmpty)
    }

    // A8: both transport failure and unreadable JSON preserve the last usable display.
    @Test func failedAndUnreadableReadsRetainPreviousReportAndExplainProblem() async throws {
        let wire = U31CostsReader()
        let store = CostsStore(reader: { day in try wire.read(day) }, calendar: u31PageCalendar())
        await store.reload()
        store.range = .week; store.group = .project
        let previous = try #require(store.report).days(last: 30)
        for mode in [U31CostsReader.Mode.failure, .malformed] {
            wire.set(mode)
            await store.reload()
            #expect(store.report?.days(last: 30) == previous)
            #expect(store.groupTotal == Decimal(string: "7.75"))
            #expect(store.problem?.isEmpty == false)
        }
    }
}

private final class U31CostsReader: @unchecked Sendable {
    enum Mode: Sendable { case good, failure, malformed }
    private let lock = NSLock()
    private var mode: Mode = .good
    func set(_ value: Mode) { lock.lock(); defer { lock.unlock() }; mode = value }
    func read(_ day: String?) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case .good: return u31CostsJSON(day: day)
        case .failure: throw CocoaError(.fileReadNoPermission)
        case .malformed: return ["now": "not-a-date", "rows": "unreadable"]
        }
    }
}
