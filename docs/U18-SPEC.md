# U18: broker list ops

The broker ops `seats`, `councils`, `routes`, `models`, `list_targets`, `findings`, `dispose` and `leaderboard` return
real data. Each reply is `{"ok":true,"data":{...},"data_note":...}`; the request's `caller` is `owner` for the CLI.
Config problems fail closed with the existing `ConfigProblem` reply (exit 4). Nothing here returns an endpoint, a key,
a pin path, or a prompt.

- `seats` -> `data.seats`: `[{name, harness, model, role, hosted, vendor}]` in config order.
- `councils` -> `data.councils`: `[{name, seats, spares, synthesizers, rule, high_risk}]`.
- `routes` -> `data.routes`: `[{callers, target, hop_limit, fallbacks, local_only}]`.
- `models` -> `data.models`: one row per distinct model, `[{model, seats:[seat names]}]`, sorted by model.
- `list_targets` -> `data.list_targets`: for caller `owner`, every seat, council and alias name; for any other caller,
  only targets with a route from that caller (by caller name, `any` included; same lookup the resolver uses, alias names
  resolved). Row: `{target, kind: "seat"|"council"|"alias", hop_limit}` (hop limit of the route; owner rows use the
  largest configured limit or 1 when no routes exist). Sorted by target. When `agent_access` is not `on`, a non-owner
  caller gets exit 3 `refused: agent access is off`.
- `findings` (`open: true` keeps only `disposition == "open"`) -> `data.findings`, the same rows as the panel's findings.
- `dispose` (`id` = claim id, `disposition` = `confirm`|`dismiss`|`will-fix`): only for caller `owner` (else exit 3).
  `confirm` and `dismiss` write the owner outcome through `OutcomeBook.dispose`, reply `data = {id, disposition}`. An
  unknown claim id exits 64 `unknown id <id>`. `will-fix` exits 64 `will-fix is not recorded yet`. Disposing a claim
  twice records the later decision (the ledger already supports superseding).
- `leaderboard` (`action` = `preview`|`publish`): only for caller `owner`. `preview` -> `data = {bytes: <the exact
  JSON text a publish would send>, cells: n}` using `LeaderboardPublisher.preview` with an empty golden map. `publish`
  runs `press`, with the `gh` client pinned to the configured repo, and replies `data = {published: true}`; any
  `LeaderboardError` is exit 4 with its message. Unknown action is exit 64.

## Acceptance
1. With a config of two seats, one council, two routes: `seats`, `councils`, `routes`, `models` return exactly those
   rows, and no reply text contains the seat endpoint or any `pin` value.
2. `list_targets` as owner lists all; as `codex` lists only routed targets; as an unrouted caller lists none; with
   `agent_access` off a non-owner gets exit 3.
3. `findings` lists seeded claims; `open` hides a claim after `dispose confirm`.
4. `dispose` writes an owner outcome (visible via the ledger), unknown id exits 64, `will-fix` exits 64, non-owner
   caller exits 3.
5. `leaderboard preview` returns bytes that pass `LeaderboardValidator`; a non-owner caller exits 3; unknown action 64;
   `publish` is not exercised against GitHub in tests.
6. An empty config returns empty lists, not an error.

## Owner attribution
`owner` is accepted only from a connection outside every seat's process tree (the same attribution `ask` uses); a seat's
child that claims it gets exit 3 `refused: a seat cannot act as the owner`. A non-seat local process can still say
`owner`: the socket is user-only (mode 0700), so that is the same trust as running the CLI. Known limit: `leaderboard
publish` reads the repo setting twice (pin and press); a change of that setting mid-press is not guarded.
