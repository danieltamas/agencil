# U19: the placeholder panes get their settings

Panes Harnesses, Models, Budgets, Scoring, Leaderboard, Data and More apps stop being placeholders. Every setting is
saved as it changes through `ConfigEditor` (re-read before write, whole config validated).

## ConfigEditor (AgencilCore/Settings)
- `set(key, value)` also accepts `retention_raw_days`, `leaderboard_repo`, `leaderboard_min_n`:
  - `retention_raw_days`: a whole number text from 1 to 3650, else `SheetProblems` on that key (same rule as `Retention.days()`).
  - `leaderboard_repo`: `owner/name` (the `LeaderboardSettings` rule), else a problem on that key.
  - `leaderboard_min_n`: whole number from 10 to 1000 else a problem (the exporter clamps below 10; the pane never offers it).
  - `leaderboard_enabled` may be set to `"0"` only (turning scheduled publishing off). Any other value is refused: only the
    first manual press turns it on.
- `addMemoryTarget(repo:folder:)`, `setMemoryTarget(repo:enabled:)`, `removeMemoryTarget(repo:)` edit the `memory_export` list
  (JSON, sorted keys), validated by the same rules as `MemoryExport.save` (`MemoryExport.validate` becomes internal). A new
  target starts `enabled: false`. Unknown repo on set/remove is a problem. Duplicate repo on add is a problem.
- `setBudget(name:scope:key:window:dollars:hard:)` and `removeBudget(name:)` edit the `budgets` list, validated by
  `SeatConfig`; a duplicate name on add is a problem; `dollars` must be >= 0.

## Broker ops
- `data` (any caller): `data = {retention_days, database_bytes, raw_bytes, total_bytes, memory_targets:[{repo,folder,enabled}]}`
  from `Retention` and `MemoryExport.targets()`. A bad `retention_raw_days` fails with exit 4 and its message.
- `prune` (owner only, non-seat as in U18): runs `Retention.prune(now:)` and replies
  `{files_deleted, bytes_freed, exchanges_cleared}`; claims, evidence, verdicts and outcomes are untouched.

## Panes
- Harnesses: rows from the `harnesses` op (found, version, signed in), a Re-check press (`probe`).
- Models: rows from the `models` op (model, the seats using it).
- Budgets: rows from the config budgets with this week's spend from the `budgets` op; New budget sheet and a Remove press.
- Scoring: read-only; states the rules (confirmed share, Wilson 95% interval, 20 decided findings to act, 30 days to
  unresolved, probation floors 50% recall and 60% confirmed share over 10 golden briefs) from the same constants the engine uses.
- Leaderboard: repo and minimum outcomes fields; "Publish daily" switch (disabled until the first manual press, off-only
  after); Preview (shows the exact JSON size and cell count) and Publish now (owner op).
- Data: retention days field, size readout (ledger, raw output), Delete old raw output now, memory export targets list with
  switches and Add/Remove.
- More apps: the sibling apps with links to their public repos.

## Acceptance
1. `set` accepts valid values for the three new keys and refuses invalid ones with a problem keyed to that key, leaving the
   file unchanged; `leaderboard_enabled` accepts only "0".
2. Memory target add/enable/remove round-trips through `MemoryExport.targets()`; duplicate and unknown repo are refused;
   a new target is disabled.
3. Budget add/remove round-trips through `SeatConfig.budgets`; duplicate name refused; negative dollars refused.
4. Broker `data` returns the shape above against a seeded home (known file sizes, one target); a bad retention value is exit 4.
5. Broker `prune` as owner deletes raw files older than the window and reports counts; as a non-owner exits 3; outcomes remain.
