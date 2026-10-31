# U20: schedulers

`Maintenance` (AgencilCore/Data) runs the background jobs the earlier units built but nothing ran. The broker calls
`run(now:)` every 60 seconds (`AGENCIL_MAINTENANCE_SECONDS` overrides it only when `AGENCIL_TEST_SEAMS=1`).

`Maintenance(ledger:directory:github:)`; `run(now: Date, calendar: Calendar = .current) -> [String]` returns the names of
the jobs it ran, in this order. State lives in `<directory>/maintenance.json` (mode 0600, atomic writes):
`{"<job>": {"last_run": <epoch seconds>, "last_error": "<message>"?, "last_attempt": <epoch>}}`. An unreadable or malformed
file counts as empty (every job is idempotent, so a repeat is safe).

| Job | Runs when | Does |
|-----|-----------|------|
| `prune` | never ran, or 24 h since `last_run` | `Retention.prune(now:)` |
| `memory` | never ran, or 10 min since `last_run` | `MemoryExport.run(now:)` |
| `learn` | never ran, or 7 days since `last_run` | `LearnLoop.propose(now:, candidates: config seats, ideas: [])` |
| `leaderboard` | `leaderboard_enabled` is `1` and: (a) no `last_run` and local time is at or after 06:00, or (b) now is at or after 06:00 local today and `last_run` is before today's 06:00, or (c) 10 or more outcomes were recorded since the last successful publish and 1 h passed since `last_run` | `LeaderboardPublisher.publishScheduled(now:, golden: [:])` |

- A job that throws records `last_error` (its message) and `last_attempt`, is not counted as run, and is tried again no
  sooner than 1 h later (`last_attempt`); other jobs still run. A success clears `last_error` and sets `last_run`.
- The leaderboard job stores `outcomes_at_publish` (the outcomes count at the last successful publish) in its state.
- `leaderboard` never runs while `leaderboard_enabled` is anything but `1`, and never makes a request then.
- An invalid config makes no job run (fail closed) and `run` returns `[]`.
- The broker's `data` op also returns `jobs: {name: {last_run?, last_error?}}`; the Data pane shows "Last cleanup" from `prune`.

## Acceptance
1. First `run` on an empty home runs prune, memory and learn (leaderboard off), writes the state file; a second `run`
   at the same instant runs nothing.
2. Time travel: +10 min runs memory only; +24 h runs prune too; +7 days runs learn too.
3. Leaderboard: off -> no GitHub call at all; on at 05:59 with no history -> nothing; at 06:00 -> publishes once (stub
   client sees the PUT and dispatch); the same day later -> nothing; next day 06:00 -> again; 10 new outcomes + 1 h after
   last run -> publishes earlier.
4. A throwing publisher records `last_error`, is not retried before 1 h, retried after, and a success clears the error;
   prune and memory still run meanwhile.
5. Corrupt `maintenance.json` is treated as empty; invalid config returns `[]` and runs nothing.
6. Broker `data` returns `jobs` with `last_run` after a pass (drive with the test seam).
