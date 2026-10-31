# U8 contract: the panel's data, bento, notifications and stop

`docs/PLAN.md` U8 and `docs/DESIGN.md` "Panel" own the look. This file fixes the part that is not a view: what the
broker tells the panel, how the bento counts, when a notification fires, and how Stop behaves. The logic lives in
`AgencilCore` (`Sources/AgencilCore/Panel/`) so it is tested without SwiftUI; the views only render it.

## The `panel` op

Broker op `panel` (read-only, no request row, CLI `agencil panel`), reply `data`:

```
{"configured": bool,                      // at least one seat and one council in config.json
 "seats":   {"total": n, "up": n, "thinking": n, "items": [{"name","model","up","thinking","probed_ago": s?}]},
 "threads": [{"id","caller","seat","question","state","reason"?,"started","ended"?}],    // newest first, at most 200
 "sittings":[{"id","no","council","state","round","started","ended"?,"cost_usd","verdict"?}],  // newest first, at most 200
 "findings":[{"id","severity","file","line","body","backers","dissenters","minority","disposition"}],
 "proposals_pending": n,
 "week": {"spend_usd": number, "budget_usd": number?},                                   // budget absent = no cap
 "live": n}                                                                             // running threads + running sittings
```

- `thread.state`: `asking`, `answered`, `failed`; `reason` only on `failed`. `question` is the first line, at most 200
  characters. `sitting.state`: the stored state (`running`, `PASS`, `BLOCK`, `INCOMPLETE`, `failed`, `stopped`).
- `finding.disposition`: `open` (no owner outcome), `confirmed`, `dismissed` or `will_fix`, from the newest `outcomes`
  row with `source = 'owner'` for the claim. `findings` lists claims of sittings, newest first, at most 200.
- `proposals_pending`: `proposals` rows whose newest status is `pending`.
- `week`: the sum of `seat_runs.cost_usd` since the start of the current ISO week (UTC); `budget_usd` the sum of the
  configured weekly caps, absent when none is set.
- A ledger or config problem is a failed reply (`ok: false`), never a partial one; the app then keeps its last data.

## Bento

`PanelModel.bento(_ data) -> Bento`, a pure function:

- `configured == false` -> `.firstStep` (the bento explains the first step; it never shows 0).
- A sitting with `state == running` -> `.council(sitting: id)` for the newest such sitting.
- Otherwise `.needsYou(count:, findings:, proposals:, stopped:)` where `findings` is the number of findings with
  `disposition == open`, `proposals` is `proposals_pending`, `stopped` is the number of sittings in the last 24 hours
  whose state is `INCOMPLETE` or `failed` that the owner has not opened (`seen` is a set of sitting ids the store
  passes in), and `count` is their sum. Confirmed, dismissed and will-fix findings never count.
- The two small tiles: Seats `"<up> of <total>"` (pulse when `thinking > 0`), This week the spend and, with a budget,
  the percentage of it.

## Notifications

`Notifier.events(previous:current:settings:) -> [PanelEvent]`, pure:

- `previous == nil` (the first read) -> no events, whatever the data holds.
- Events, each once per change between two reads:
  - `verdict(sitting, PASS|INCOMPLETE)` when a sitting moved from `running` to that state;
  - `block(sitting)` when it moved to `BLOCK` (not also a `verdict`);
  - `seatDied(seat)` when a seat went from up to down;
  - `budget(percent)` when the week's share crosses 80% upward (not on every read above it; it re-arms below 80%);
  - `threadFailed(thread)` when a thread moved to `failed`.
- `settings.notify` is a set of kinds (`verdict`, `block`, `seat`, `budget`, `thread`); a kind that is not in it
  produces no event. The `config.json` key `notify` holds the kinds as JSON text (a list of strings); absent means all
  five; an invalid value is a `ConfigProblem`. The General pane toggles each kind and saves as it changes.

## Stop

`StopControl` (one per sitting id, in the panel store), `press(_ id) async`:

- First press: state becomes `stopping` at once (before any broker reply) and the broker `stop` op runs for the id.
- A press while `stopping` does nothing (the stop op is called once).
- When the broker reply is `ok` the control leaves `stopping` on the next read that shows a final state; a failed
  reply returns it to `idle` and reports the reason.
- The broker's `stop` ends the seat process groups (U7a); the control adds no kill of its own.

## Acceptance (observable)

- `panel` on a fresh home: `configured: false`, empty lists, `live: 0`; with seats and councils configured and the
  stub fixtures, the counts and rows match the ledger.
- Bento fixture: 3 open findings, 2 confirmed, 1 pending proposal gives `count == 4`; adding one unseen
  `INCOMPLETE` sitting gives 5, seen gives 4.
- No config -> `.firstStep`. A running sitting -> `.council`.
- Notifier: first read gives `[]`; running -> BLOCK gives one `block`; crossing 80% gives one `budget`, the next read
  above 80% gives none; a disabled kind gives none.
- Stop: the first press shows `stopping` before the broker answers; a second press calls the op zero more times.
- Layout (`Tests/AgencilTests/Layout`): the panel is 404 pt wide in every tab and look; every row control is 28 pt;
  the long repo, model id and reason fit; every empty and waiting state renders in every look.

## Known limits (recorded, not hidden)

- A seat is `up` when its harness is installed (an Ollama seat: when it has an endpoint). Probed health, and so seat-down
  notifications for an unreachable endpoint, arrive with the Harnesses and Models panes (U9).
- Confirm, Dismiss and Will fix, and the sitting expansion (seat lines, claim timeline, report), arrive with U10 and U11.
  Opening a sitting row records it as seen, which clears it from "Needs you".
