# U31 - Costs pane

Settings > Costs, the same logic and layout as Bton's Settings > Costs (`~/Sites/bton/Sources/Bton/CostsPane.swift`,
`Sources/BtonCore/CostLedger.swift`), over Agencil's ledger: what every seat call on this Mac has cost, by day, and grouped by
project, council, seat, model or caller. Read-only; nothing in it changes a setting.

## Behavior

1. **Source.** One row per exchange (`exchanges` joined to `threads`), the seat's own call, whether it was a direct ask, a
   sitting round, a synthesis or a follow-up. `seat_runs` is not summed (it repeats the sitting exchanges). The cost is the
   exchange's `cost_usd`; its tokens are `tokens_in` and `tokens_out`. An exchange that answered and has no `cost_usd` is
   **unpriced**: counted as a call, never as money. An exchange that did not answer (failed, stopped, still asking) is not a
   call and is left out. The day is the exchange's `created_at` in the local calendar.
2. **Groups.** `project` (the thread's `run_origins.project`, else the sitting's, else `unknown`), `council` (the sitting's
   council through `thread_rounds`, else `direct`), `seat` (`threads.seat`), `model` (the exchange's recorded model, else
   `unknown`), `caller` (`threads.caller`). A group row has `name`, `calls`, `unpriced`, `cost`.
3. **Report in AgencilCore.** `CostReport(rows:now:calendar:)` over `CostRow {day, project, council, seat, model, caller, calls,
   unpriced, cost}` (one per distinct day and group key). It offers `days(last:)` (one `Day {date, cost, calls, unpriced}` per
   calendar day ending today, zeros where nothing ran), `rows(by:from:to:)` (dearest first; ties by calls then name),
   `months()` (newest first, each with total, unpriced and its projects). Money is `Decimal`; a total never hides an unpriced
   call.
4. **Op `costs`** (read-only, any local caller like `detail`): `{op:"costs"}` returns `rows[]` (the aggregated rows above, a day as
   `YYYY-MM-DD` in the machine's local calendar) and `now`. `{op:"costs", day:"YYYY-MM-DD"}` also returns `entries[]`: the
   answered exchanges of that day, newest first, at most 200, each `{thread, sitting?, seat, model, caller, project, council,
   cost?, tokens_in?, tokens_out?, at}`; `cost` is absent when unpriced. A malformed `day` is exit 64.
5. **Off the main thread.** The pane asks the broker through the panel client on a background task, once on appear and again
   when the panel's data changes while it is open; a read failure keeps what is shown and says why in a `ProblemText`.
6. **The pane** (`SettingsPane.costs`, title "Costs", symbol `dollarsign.circle`, tint `.caution`, placed after Budgets):
   a header; a **Last 30 days** card with 30 bars scaled to the dearest day (today in the mint accent, empty days faint, hover
   or selection lights a bar), a caption under the title that reads the total and calls, or the hovered/selected day's
   `weekday, day month: $ - n calls - n unpriced`, an "All days" chip when a day is selected, and below the bars the selected
   day's entries (a tap opens that thread or sitting on the panel); a **By** card with the range chips `Today`, `7 days`,
   `30 days`, `This month`, the group chips `Project`, `Council`, `Seat`, `Model`, `Caller`, the range total, and one meter row
   per group (name, `n unpriced`, `n calls`, the cost, a share bar; a vendor mark beside a model); a **Months** card (month name,
   total, `n unpriced`, its projects as `name $x - name $y`); a short **Records** note that the costs stay in the ledger when the
   Data pane prunes the question and answer text (no control here: retention is the Data pane's). "Nothing ran in this range."
   and "none yet" for the empty states.
7. **Kit.** New Kit parts, none importing AgencilCore: `BarStrip` (the 30 bars), `ShareBar` (the capsule meter row) and `Money`
   (the cost text). All sizes from `Size`/`Space`/`Radius`. Both the pane and the demo catalog (`DemoCatalog`) list the new pane;
   demo data uses made-up names (harbor/checkout, lumen/api).
8. **Enumerations.** Every place that lists the settings panes lists `.costs` (sidebar, demo catalog, screenshot command,
   guard tests that walk `SettingsPane.allCases`).

## Acceptance

A1. `CostReport` over fixed rows: `days(last: 30)` returns 30 days ending today with zero days present; totals, calls and
    unpriced add per day.
A2. `rows(by:from:to:)` for every group returns the rows dearest first with the tie rule, covers only days in `[from, to)`,
    and its costs add up to the same total for every group.
A3. `months()` is newest first; each month's total equals the sum of its projects.
A4. A ledger of direct asks, sitting rounds, a synthesis and a follow-up: the `costs` op returns one aggregated row per distinct
    day and group key; the sum of `calls` equals the answered exchanges; an answered exchange with no `cost_usd` adds to
    `unpriced` and never to `cost`; a failed or asking exchange is not counted; no `seat_runs` double count.
A5. Project, council, seat, model and caller resolve as item 2 says, including `unknown` and `direct`, and a follow-up thread
    counts under its sitting's council and project.
A6. `costs` with `day` returns that day's entries newest first, capped at 200, `cost` absent when unpriced; a malformed `day` is
    exit 64; a day with nothing returns an empty list.
A7. The op reads a ledger whose question/answer text has been pruned (nulled) and returns the same costs.
A8. The pane's view-model maps the op JSON into the report and fails closed: an unreadable reply keeps the previous report and
    sets a problem; no mutation anywhere.
A9. Layout guards: the pane renders in the settings window at its minimum size without clipping, the bars fit 30 across, the
    By card's chips wrap, the group lines keep a fixed row height; every spacing is a token; `SettingsPane.allCases` includes
    `.costs` after `.budgets`.

## Interfaces (tests compile against these exact names)

AgencilCore (`Sources/AgencilCore/Panel/CostReport.swift`, `CostsOp.swift`):
```swift
public struct CostRow: Hashable, Sendable {
    public let day: String            // YYYY-MM-DD, local calendar
    public let project, council, seat, model, caller: String
    public let calls: Int, unpriced: Int
    public let cost: Decimal
    public init(day: String, project: String, council: String, seat: String, model: String, caller: String,
                calls: Int, unpriced: Int, cost: Decimal)
}
public enum CostGroup: String, CaseIterable, Sendable { case project, council, seat, model, caller }
public struct CostEntry: Hashable, Sendable {
    public let thread: String, sitting: String?, seat: String, model: String, caller: String, project: String, council: String
    public let cost: Decimal?, tokensIn: Int?, tokensOut: Int?, at: String
}
public struct CostReport: Sendable {
    public struct Day: Hashable, Sendable { public let date: Date; public let cost: Decimal; public let calls: Int; public let unpriced: Int }
    public struct GroupRow: Hashable, Sendable { public let name: String; public let calls: Int; public let unpriced: Int; public let cost: Decimal }
    public struct Month: Hashable, Sendable { public let month: String; public let total: Decimal; public let unpriced: Int; public let projects: [GroupRow] }
    public init(rows: [CostRow], now: Date = .now, calendar: Calendar = .current)
    public init(json: [String: Any], calendar: Calendar = .current) throws   // the op's data object
    public func days(last n: Int) -> [Day]
    public func rows(by group: CostGroup, from: Date, to: Date) -> [GroupRow]
    public func months() -> [Month]
    public static func entries(json: [String: Any]) -> [CostEntry]
}
```
Op: `{"op":"costs"}` -> data `{now: ISO8601, rows: [{day, project, council, seat, model, caller, calls, unpriced, cost}]}`;
with `day` -> also `entries: [{thread, sitting?, seat, model, caller, project, council, cost?, tokens_in?, tokens_out?, at}]`.
`cost` is a JSON number (dollars).

App (`Sources/Agencil/Store/CostsStore.swift`):
```swift
@MainActor @Observable final class CostsStore {
    enum Range: String, CaseIterable { case today = "Today", week = "7 days", month = "30 days", thisMonth = "This month" }
    var report: CostReport?; var entries: [CostEntry]; var problem: String?
    var selectedDay: Date?; var range: Range; var group: CostGroup
    init(reader: @escaping @Sendable (_ day: String?) async throws -> [String: Any], calendar: Calendar = .current)
    func reload() async                      // fetches rows; on failure keeps report, sets problem
    func select(_ day: Date?) async          // sets selectedDay, fetches entries (cleared on nil)
    var window: (from: Date, to: Date) { get }          // per Range, as Bton
    var groupRows: [CostReport.GroupRow] { get }        // rows(by: group, window)
    var groupTotal: Decimal { get }
}
```
Kit: `BarStrip(bars: [BarStrip.Bar], onSelect: (Int) -> Void)` with `Bar {id: String, share: Double, today: Bool, lit: Bool, filled: Bool, help: String}`;
`ShareBar(share: Double)`; `Money(value: Decimal)`.
Pane: `CostsPane(store: CostsStore, open: (String) -> Void)`.
