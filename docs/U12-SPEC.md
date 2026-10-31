# U12 contract: the learn loop

`docs/PLAN.md` U12 owns the rules. Testable surface in `AgencilCore` (`Sources/AgencilCore/Learn/`), all public,
tests use `import AgencilCore`, `Ledger(directory:)`, `ConfigStore(directory:)` and seed outcome rows by SQL
like the U11 tests (`OutcomeBook.scoreboard` is the data source). Dates are injected.

```swift
public enum ProposalKind: String, Sendable { case dropSeat = "drop_seat", addSeat = "add_seat", swapSeat = "swap_seat", promptChange = "prompt_change" }
public enum ReviewVerdict: String, Sendable { case endorse, object }
public struct PromptIdea: Equatable, Sendable { public init(council: String, variable: String, value: String) }
public struct Proposal: Equatable, Sendable {
    public let id: String; public let kind: ProposalKind; public let council: String
    public let seat: String?          // the seat dropped or swapped out
    public let replacement: String?   // the seat added or swapped in
    public let variable: String?; public let value: String?   // prompt change
    public let status: String         // proposed, reviewed, applied, rejected, rolled_back
    public let n: Int                 // outcomes behind it (see rules)
    public let evidence: String       // JSON text: {"n":..,"cell":{..},"confirmedShare":{"numerator":..,"denominator":..}}
    public let reviewer: String?; public let verdict: ReviewVerdict?
}
public struct ConfigVersion: Equatable, Sendable { public let version: Int; public let hash: String; public let body: String }

public final class LearnLoop: @unchecked Sendable {
    public static let minOutcomes = 20
    public init(ledger: Ledger, directory: URL)      // directory holds config.json
    public func propose(now: Date, candidates: [Seat], ideas: [PromptIdea]) throws -> [Proposal]
    public func proposals() throws -> [Proposal]     // every proposal, oldest first
    public func reviewer(for proposal: String) throws -> Seat?
    public func review(_ proposal: String, by: Seat, verdict: ReviewVerdict, note: String, at: Date) throws
    public func approve(_ proposal: String, at: Date) throws -> ConfigVersion
    public func reject(_ proposal: String, at: Date) throws
    public func versions() throws -> [ConfigVersion] // council config versions, oldest first
    public func rollback(at: Date) throws -> ConfigVersion
}
```

## Rules
- Data: `OutcomeBook(ledger:).scoreboard(now:)` cells (seat, council). A cell's **n** is its `confirmedShare.denominator`
  (decided findings). Seats and councils come from `config.json` (`ConfigStore`, keys `seats`, `councils`).
- **No proposal under `minOutcomes` (20) in the cell.** A council-level proposal (add, prompt) needs n >= 20 summed over the council's cells.
- `drop_seat`: a cell with n >= 20 whose Wilson upper bound of confirmed share is below 0.30, and the council keeps at least 2 seats after the drop.
  When `candidates` holds a seat not in the council whose vendor differs from the dropped seat's vendor, propose `swap_seat` with the first such candidate instead.
- `add_seat`: every cell of a council with `coverage.denominator >= 20` has `coverage.value < 0.5`, at least 2 such cells, and a candidate not in the council exists (first one).
- `prompt_change`: for each `PromptIdea` whose council has n >= 20 (council-level). At most one open (proposed or reviewed) prompt change per council, and a new variable name
  is refused while the council has an applied prompt change with a different variable (one variable at a time). The change sets key `prompt_variant` = `{"variable":..,"value":..}` on the council's JSON object.
- No duplicate: a (kind, council, seat/variable) with an open proposal is not proposed again. Each call returns only the proposals it wrote; calling twice in a row writes nothing the second time.
- **Reviewer**: `reviewer(for:)` is the first seat in config order whose vendor differs from the vendor of every seat the proposal touches (`seat`, `replacement`, and for a prompt change every seat of the council). nil when none. `review` throws when `by` (resolved by name in config; the caller's copy is not trusted) shares a vendor with a touched seat, when the proposal is not `proposed`, or `by` is unknown. It records reviewer, verdict, note and sets status `reviewed`.
- **Owner approval**: `approve` is the only call that changes `config.json`. It throws unless status is `reviewed`. It writes the baseline version first when no version exists (version 1 = the current `councils` value), applies the change to the `councils` value in one `ConfigStore.update` based on the revision it read (a stale revision or a council/seat that no longer matches throws and changes nothing), records the new `ConfigVersion` (hash = lowercase hex SHA-256 of the exact `councils` string stored, body = that string), and sets status `applied`.
  Drop removes the seat from the council's `seats`; add appends; swap replaces in place; the result is validated with `SeatConfig(values:)` and refused if invalid. Nothing is applied without `approve`: `propose`, `review`, `reject` and a failed `approve` leave `config.json` byte-identical.
- `reject` works on `proposed` or `reviewed` and sets `rejected`; never touches config.
- **Rollback**: restores the `councils` value of the version before the latest into `config.json` and records it as a new version whose hash equals that earlier version's hash; the proposal behind the rolled-back version becomes `rolled_back`. Throws when there is no previous version.
- After `approve`, `SeatConfig(values: store.read().values)` already shows the new council (the next sitting reads config each time).

## Acceptance
As PLAN U12 "Acceptance" (one test each), plus: n 19 writes nothing and n 20 writes; Wilson bound rule boundary; drop refused at 2 seats; swap preferred with a different-vendor candidate; add rule; prompt single-variable rule; second `propose` writes nothing; reviewer never shares a vendor with a touched seat; `review` rejects a forged `Seat` copy; approve before review throws; approve is byte-exact on untouched config keys; stale revision approve throws and changes nothing; rollback hash equals version 1 hash and bytes of `councils`; evidence JSON carries n.

## Accepted limits
- The weekly schedule, the reviewer's actual spawn, and the panel's approve/reject buttons are wiring on top of this API and land with U15/U16 integration.
- Review follow-ups: approve and rollback hold one ledger transaction open across the `config.json` write (status, revision and
  validity are checked inside it; a failed commit puts the old councils back). A review made at an older config revision is stale
  and may be made again. A second `rollback` restores the version before the latest, which after a rollback re-applies the
  rolled-back version. The reviewer independence rule trusts a seat's vendor only when its harness serves one vendor
  (claude, codex, gemini) or the owner wrote `vendor` in the seat; a generic harness without it can neither review nor be reviewed against.
- Not covered: a crash between the config rename and the ledger commit leaves the new councils without a version row (the next
  approve records the current councils as a version first).
