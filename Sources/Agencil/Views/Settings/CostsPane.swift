import AgencilCore
import SwiftUI

/// Settings > Costs: what every seat call on this Mac has cost, by day, by project, council, seat, model or caller, and by month.
/// Read-only, from the ledger the broker keeps (docs/U31-SPEC.md).
struct CostsPane: View {
    let store: CostsStore
    let open: (String) -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            if let problem = store.problem { ProblemText(text: problem) }
            if let report = store.report {
                daysCard
                groupsCard
                monthsCard(report)
                SettingsCard(title: "Records") {
                    Text("The costs stay in the ledger when the Data pane prunes the question and answer text of old calls.")
                        .font(.house.meta).foregroundStyle(Theme.textTertiary).paragraph()
                }
            }
        }
    }

    // MARK: days

    private var daysCard: some View {
        let days = store.days
        let peak = days.map(\.cost).max() ?? Decimal.zero
        let shown = hovered.flatMap { index in days.indices.contains(index) ? days[index].date : nil } ?? store.selectedDay
        let bars = days.map { day in
            BarStrip.Bar(id: CostReport.day(of: day.date, calendar: .current),
                         share: peak > Decimal.zero ? NSDecimalNumber(decimal: day.cost / peak).doubleValue : Double.zero,
                         today: Calendar.current.isDateInToday(day.date), lit: shown == day.date,
                         filled: day.calls > Int.zero, help: caption(day))
        }
        let line = days.first { day in day.date == shown }.map(caption) ?? "\(Money.text(store.barsCost)) - \(store.barsCalls) calls"
        return Bezel {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Last 30 days").font(.house.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(line).font(.house.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    }
                    Spacer()
                    if store.selectedDay != nil {
                        PillButton(title: "All days", symbol: "xmark", prominent: false) { store.showAllDays() }
                    }
                }
                BarStrip(bars: bars, onSelect: { index in store.choose(days[index].date) }, onHover: { hovered = $0 })
                if store.selectedDay != nil {
                    RowDivider()
                    dayEntries
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func caption(_ day: CostReport.Day) -> String {
        let when = day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        let unpriced = day.unpriced > Int.zero ? " - \(day.unpriced) unpriced" : ""
        return "\(when): \(Money.text(day.cost)) - \(day.calls) calls\(unpriced)"
    }

    private var dayEntries: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.entries.isEmpty {
                Text("No calls recorded for this day.").font(.house.meta).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(store.entries.enumerated()), id: \.offset) { _, entry in entryLine(entry) }
        }
    }

    private func entryLine(_ entry: CostEntry) -> some View {
        PressRow(label: "Open \(entry.seat) call") { open(entry.sitting ?? entry.thread) } content: {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(entry.seat) - \(entry.council)").font(.house.control).foregroundStyle(Theme.textPrimary)
                    Text("\(entry.project) - \(entry.caller) - \(entry.model)").font(.house.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                if let cost = entry.cost {
                    Money(value: cost)
                } else {
                    Text("no price").font(.house.badge).foregroundStyle(Theme.warn)
                }
            }
            .padding(.vertical, Space.s)
        }
    }

    // MARK: groups

    private var groupsCard: some View {
        let rows = store.groupRows
        let total = store.groupTotal
        return SettingsCard(title: "By", detail: "Where the money went in the range, dearest first.") {
            VStack(alignment: .leading, spacing: Space.l) {
                FlowLayout {
                    ForEach(CostsStore.Range.allCases, id: \.self) { choice in
                        SegmentChip(title: choice.rawValue, selected: store.range == choice) { store.pick(range: choice) }
                    }
                }
                FlowLayout {
                    ForEach(CostGroup.allCases, id: \.self) { choice in
                        SegmentChip(title: choice.rawValue.capitalized, selected: store.group == choice) { store.pick(group: choice) }
                    }
                }
                Money(value: total, font: .house.statSmall)
                if rows.isEmpty {
                    Text("Nothing ran in this range.").font(.house.meta).foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.name) { row in groupLine(row, total: total) }
                    }
                }
            }
        }
    }

    private func groupLine(_ row: CostReport.GroupRow, total: Decimal) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.m) {
                Text(row.name).font(.house.control).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Space.m)
                if row.unpriced > Int.zero {
                    Text("\(row.unpriced) unpriced").font(.house.badge).foregroundStyle(Theme.warn).lineLimit(1)
                }
                Text("\(row.calls) calls").font(.house.meta).foregroundStyle(Theme.textTertiary).monospacedDigit().lineLimit(1)
                Money(value: row.cost).lineLimit(1)
            }
            ShareBar(share: total > Decimal.zero ? NSDecimalNumber(decimal: row.cost / total).doubleValue : Double.zero)
        }
        .padding(.vertical, Space.s)
    }

    // MARK: months

    private func monthsCard(_ report: CostReport) -> some View {
        let months = report.months()
        return SettingsCard(title: "Months", detail: "Each month's total and its projects, from every call the ledger holds.") {
            VStack(alignment: .leading, spacing: 0) {
                if months.isEmpty {
                    Text("none yet").font(.house.meta).foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(months.enumerated()), id: \.element.month) { index, month in
                    if index > Int.zero { RowDivider() }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            Text(CostsStore.monthName(month.month)).font(.house.control).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if month.unpriced > Int.zero {
                                Text("\(month.unpriced) unpriced").font(.house.badge).foregroundStyle(Theme.warn)
                            }
                            Money(value: month.total)
                        }
                        Text(month.projects.map { project in "\(project.name) \(Money.text(project.cost))" }.joined(separator: " - "))
                            .font(.house.meta).foregroundStyle(Theme.textTertiary).monospacedDigit().paragraph()
                    }
                    .padding(.vertical, Space.m)
                }
            }
        }
    }
}
