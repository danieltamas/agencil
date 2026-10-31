# U22 - learn proposals in the broker and the panel

The learn loop (U12) writes proposals, but nothing lets the owner see or decide them. This unit adds two broker
ops and the panel rows. It does not spawn the reviewing seat (that stays open), so a proposal reaches `reviewed`
only through `LearnLoop.review`.

## Broker ops (Sources/AgencilCore/Broker/BrokerLearn.swift)

- `proposals` (read, any local caller, like `findings`). Reply `data`:
  `{"proposals": [{"id","kind","council","seat","replacement","variable","value","status","n","reviewer","verdict","note"}], "can_rollback": Bool}`.
  Only open proposals (`proposed`, `reviewed`) unless the request carries `"all": true`. Absent optional fields are
  JSON null. `can_rollback` is true when the ledger holds two or more council versions. Validates the config first
  (an invalid config is the usual `Failure`, as `findings`).
- `learn` (write, owner only: `requireOwner`, so a seat child is refused with exit 3). Request: `action` is
  `approve`, `reject` or `rollback`; `id` is required for approve and reject and absent for rollback. Calls
  `LearnApply.approve`, `LearnReview.reject`, `LearnApply.rollback` with `Date()`. Replies
  `{"action", "id"?, "version"?}`. A `LearnError` becomes `Failure` exit 4 with its message; a missing or unknown
  action is exit 64. `approve` of a `proposed` (unreviewed) proposal is therefore refused by U12 and changes nothing.
- The `panel` op's `proposals_pending` counts proposals whose status is `proposed` or `reviewed` (it counted a
  status the loop never writes).
- CLI: `agencil proposals [--all]`, `agencil learn approve|reject <id>`, `agencil learn rollback` as thin clients.
  docs/AGENT-API.md gets the three rows.

## Panel

- `PanelStore` reads `proposals` after each panel read (best effort: a failure leaves the last list) and exposes
  `proposals`, `canRollback`, and `decideProposalAction(id, approve:)` / `rollbackAction()` closures that make one
  `learn` call, then refresh. One in-flight decision per proposal id; a failure message survives the refresh.
- The Seats tab shows, above the seats, one row per open proposal: kind and council, the seat change, evidence n,
  status chip (`proposed` or `reviewed`), the reviewer's verdict and note when reviewed. Buttons: Reject always,
  Approve only when `reviewed` and the verdict is `endorse`. A Rollback chip shows when `canRollback`.
- Kit rules apply: tokens only, async through AsyncPress and store closures.

## Acceptance

1. `proposals` lists a seeded `proposed` and `reviewed` proposal with the fields above and omits an `applied` one;
   `all: true` includes it; `can_rollback` is false with no versions.
2. `learn` with `caller: owner` and `action: reject` sets the proposal `rejected`; a second reject is exit 4.
3. `learn approve` on a `proposed` proposal is exit 4 and `config.json` is byte-identical.
4. `learn approve` on a reviewed proposal applies it (council seats change), `can_rollback` becomes true, and
   `learn rollback` restores the councils.
5. A non-owner caller gets exit 3 on `learn`; unknown action is exit 64.
6. `panel` `proposals_pending` counts one `proposed` plus one `reviewed` proposal as 2.
7. CLI parses `proposals`, `learn approve <id>`, `learn rollback` and rejects `learn bogus`.
