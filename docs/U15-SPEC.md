# U15: council cutover (fixtures done, wrapper blocked)

`docs/PLAN.md` U15 asks for fixtures of the owner's existing council script first, then a wrapper over `agencil wake` that
reproduces them. This unit lands the first half and records why the second half waits.

## Done: the fixtures (acceptance bullet 1)
- `Tests/Fixtures/council-script/stubs/{codex,opencode,claude}`: stub seats. They log every call and obey `STUB_DEAD_MODELS`,
  `STUB_THIN_MODELS` and `STUB_CODEX_LIMIT`.
- `Tests/Acceptance/U15/council-scenarios.sh <script> <out>` runs a council script over seven scenarios and records, per scenario,
  `argv.txt` (every stub call, sorted), `files.txt` (files written, with line counts), `stdout.txt` (normalized, sorted) and `exit.txt`.
- Scenarios: `default` (default panel, exit 0), `override` (seat-list environment override and cap, exit 0), `degraded` (a thin seat
  retried once, exit 3), `probe-spare` and `probe-all-dead` (probe-only output, spare swap and dropped seats), `codex-limit`
  (the codex seat swapped for a claude seat), `no-brief` (exit 2).
- `Tests/Acceptance/U15/test_council_parity.sh <script>` replays the scenarios and diffs against the fixtures;
  `--capture <old-script>` regenerates them. Run against the old script it prints `council parity: ok`, so the capture is reproducible.
  The old script is not in this repository (it is the owner's); the fixtures hold only stub output.

## Blocked: the wrapper (acceptance bullets 2 and 3)
A wrapper cannot reproduce the fixtures yet; the engine lacks these, each a decision for the owner rather than a wrapper detail:
1. `agencil wake` takes a configured council. The old script's `COUNCIL_SEATS` override and `COUNCIL_CAP` have no wake flag.
2. A sitting returns a verdict. The old script leaves one report file per seat (`<label>.md`, the raw stdout, the codex trace);
   the wrapper would need a per-seat answer export from the ledger.
3. `harnesses --probe` is a stub in the broker (`"harnesses"` returns an empty list); the old probe-only mode also swaps dead
   opencode seats for spares, which Agencil expresses as route fallbacks, not as a probe side effect.
4. The old banner lines and exit 3 for a degraded council map to a sitting's `INCOMPLETE` (exit 2) in the CLI contract.
Once 1 to 3 exist, the wrapper is `council.sh` forwarding to `agencil wake`, checked by `test_council_parity.sh`.
