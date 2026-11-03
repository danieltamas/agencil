import AgencilCore
import Foundation
import Observation
import SwiftUI

/// What the Costs pane shows (docs/U31-SPEC.md): the report over the broker's `costs` op, the range and group the owner
/// picked, and the entries of a selected day. Read-only; a failed read keeps what is shown and says why.
@MainActor @Observable final class CostsStore {
    enum Range: String, CaseIterable { case today = "Today", week = "7 days", month = "30 days", thisMonth = "This month" }

    /// The days the bars show.
    static let barDays = 30

    private(set) var report: CostReport?
    private(set) var entries: [CostEntry] = []
    private(set) var problem: String?
    private(set) var selectedDay: Date?
    var range = Range.month
    var group = CostGroup.project

    @ObservationIgnored private let reader: @Sendable (String?) async throws -> [String: Any]
    @ObservationIgnored private let calendar: Calendar
    /// Reads finish in any order; only the one asked last may change what is shown.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var entryGeneration = 0

    init(reader: @escaping @Sendable (String?) async throws -> [String: Any], calendar: Calendar = .current) {
        self.reader = reader
        self.calendar = calendar
    }

    /// The broker's op, through the panel's client.
    convenience init(client: PanelClient) {
        self.init(reader: { day in try await client.call("costs", day.map { ["day": $0] } ?? [:]) })
    }

    func reload() async {
        generation += 1
        let mine = generation
        do {
            let next = try CostReport(json: try await reader(nil), calendar: calendar)
            guard mine == generation else { return }
            report = next
            problem = nil
        } catch {
            guard mine == generation else { return }
            problem = error.localizedDescription
        }
        if selectedDay != nil { await select(selectedDay) }
    }

    func select(_ day: Date?) async {
        // A new selection drops the old list at once and outdates any read still in flight.
        if day != selectedDay { entries = [] }
        selectedDay = day
        entryGeneration += 1
        let mine = entryGeneration
        guard let day else { entries = []; return }
        do {
            let reply = try await reader(CostReport.day(of: day, calendar: calendar))
            guard mine == entryGeneration else { return }
            entries = try CostReport.checkedEntries(json: reply)
        } catch {
            guard mine == entryGeneration else { return }
            problem = error.localizedDescription
        }
    }

    /// The days of the range, today the last of them.
    var window: (from: Date, to: Date) {
        let now = report?.now ?? Date()
        let today = calendar.startOfDay(for: now)
        let to = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch range {
        case .today: return (today, to)
        case .week: return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, to)
        case .month: return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, to)
        case .thisMonth: return (calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today, to)
        }
    }

    var groupRows: [CostReport.GroupRow] { report?.rows(by: group, from: window.from, to: window.to) ?? [] }

    var groupTotal: Decimal { groupRows.reduce(0) { $0 + $1.cost } }
}

extension CostsStore {
    /// A month of made-up spend for screenshots and layout tests: harbor and lumen asking a panel and two seats.
    static func demo(now: Date = DemoStore.now) -> CostsStore {
        let store = CostsStore(reader: { _ in [:] })
        let calendar = Calendar.current
        let projects = ["harbor/checkout", "lumen/api", "orbit/web"]
        let rows = (0..<45).flatMap { back -> [CostRow] in
            guard let date = calendar.date(byAdding: .day, value: -back, to: now), back % 5 != 3 else { return [] }
            return projects.enumerated().compactMap { index, project -> CostRow? in
                guard (back + index) % 3 != 0 else { return nil }
                let seat = index == 1 ? "maya" : "jonas"
                return CostRow(day: CostReport.day(of: date, calendar: calendar), project: project, council: index == 2 ? "direct" : "panel",
                               seat: seat, model: index == 1 ? "lumen-large" : "harbor-model", caller: index == 0 ? "lee" : "owner",
                               calls: 2 + index, unpriced: back == 0 && index == 1 ? 1 : 0,
                               cost: Decimal(string: "\(1 + (back * 7 + index * 3) % 9).\(25 * (index + 1) % 100)") ?? 1)
            }
        }
        store.report = CostReport(rows: rows, now: now, calendar: calendar)
        return store
    }
}

extension CostsStore {
    /// Press targets for the views: a view never starts a task itself.
    func choose(_ day: Date) { Task { await select(selectedDay == day ? nil : day) } }
    func showAllDays() { Task { await select(nil) } }

    func pick(range next: Range) { withAnimation(Motion.spring) { range = next } }
    func pick(group next: CostGroup) { withAnimation(Motion.spring) { group = next } }

    var days: [CostReport.Day] { report?.days(last: Self.barDays) ?? [] }
    var barsCost: Decimal { days.reduce(Decimal.zero) { total, day in total + day.cost } }
    var barsCalls: Int { days.reduce(0) { total, day in total + day.calls } }

    /// "March 2030" for "2030-03".
    static func monthName(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

extension SettingsStore {
    /// The Costs pane reads the ledger when it opens and again every few seconds while it stays open.
    func loadCosts() {
        costsLoop?.cancel()
        costsLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.costs.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopCosts() {
        costsLoop?.cancel()
        costsLoop = nil
    }
}
