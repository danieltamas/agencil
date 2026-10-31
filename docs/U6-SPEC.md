# U6 split and the U6a contract

U6 in `docs/PLAN.md` is four independent pieces. Each is built and reviewed on its own, in this order, with the
acceptance lines of U6 assigned to the piece that owns them:

| Piece | Holds | U6 acceptance lines it owns |
|-------|-------|-----------------------------|
| U6a | Seat, route and alias config; resolution steps 1 to 5; adapters and their argv; ask, result and threads with follow-ups; fallbacks and substitution records | no route refused and runs nothing; fallback on not signed in (and none: `failed: <reason>`); follow-up reaches the same seat and its stub receives the earlier exchange; harness hardened argv tests |
| U6b | Capability, process-tree attribution, hop limit, cycles, replay | the chain tests (A asks B asks C, hop 3 refused, cycle, stripped env, replaced capability, replayed capability, CLI recursion, detached process, failed peer-pid read) |
| U6c | Budgets, reservations, capacity, parked ancestors, memory floor | seats-at-once 1 chain, process cap, two concurrent asks over one budget, 1,000 randomized asks, unbounded seat on hard cap, `max_tokens` reservation, worst case over remaining budget |
| U6d | Confinement and redaction, residency, briefs in the worktree | briefs under `.agencil/`, hosted seat on local-only council, outbound packet redaction, confined stub reads, adapter that cannot enforce read-only refuses |

Anything a later piece needs is a seam in the earlier one, never a rewrite: U6a leaves `Resolution.reserve` and
`Resolution.attribute` as no-op stages that U6b and U6c fill.

## U6a contract

### Config

`config.json` values are flat strings, so each collection is one key holding JSON text. Written through
`ConfigStore`, validated on every read; a value that does not validate makes every ask fail with
`failed: config <key> is invalid: <problem>` and runs nothing.

`seats`: array of
`{"name": str, "harness": "claude|codex|opencode|hermes|gemini|aider|goose|ollama", "model": str, "endpoint": str?,
"pin": str?, "role": "finder|skeptic|synthesizer|answerer", "hardening": [str], "cap": {"seconds": int, "tokens": int?}}`.
Names are unique, `[a-z0-9][a-z0-9-]{0,39}`.

`routes`: array of
`{"callers": [str], "target": str, "hop_limit": int (1...4, default 2), "fallbacks": [str]}`.
A caller is a harness kind, a named caller id, or `any`. A target is a seat name, a council name or an alias.
Every fallback must be a seat name.

`aliases`: object `{"reviewer": "codex-gpt"}`; a value is a seat name (council aliases arrive with U7). An alias
that points at nothing, or at another alias, is invalid.

### Resolution (docs/AGENT-API.md steps 1 to 5)

`Resolver.resolve(caller:, target:, home:, now:)` returns `Resolved` (the seat that will run, the route, the
substitution if any) or a `Refusal(exitCode, reason)`. Reasons, exactly:

1. no route: `refused: no route from <caller> to <target>` (exit 3). Route matching: the caller id, else the
   caller's harness kind, else `any`; the first route whose target equals the requested name, or the alias it
   resolves to, wins. Nothing runs and no thread is created.
2. unknown target after a route matched: `failed: no seat or alias named <target>` (exit 4).
3. harness: the newest detected install whose version satisfies the seat's `pin` (equal, or a prefix at a dot
   boundary), signed in (a probe whose sign-in state is unknown counts as usable only when the catalog entry has
   no status command), probe younger than 10 minutes else probe now. None usable: try the route's fallbacks in
   order, each through steps 3 and 4; the first usable one answers and the thread records
   `answered by <fallback>, fallback for <seat>: <reason>`. None: `failed: <reason>` (exit 4) where reason is the
   first failure of the requested seat, e.g. `claude not signed in`, `codex is not installed`,
   `codex 0.9.4 is outside the pin 1.x`.
4. model and endpoint: for harness `ollama`, `GET <endpoint>/api/tags` must answer and list the model, else
   `failed: <endpoint> down` or `failed: model <model> not loaded at <endpoint>`; fallbacks apply here too.
   A hosted harness needs its key; keys are U9, so in U6a a missing key is never raised.
5. residency and budget: stages, no-ops in U6a (`Resolution.reserve`).

### Adapters

`Adapter.command(seat:, executable:, prompt:, answerFile:, runDirectory:) -> Invocation` is pure.
`Invocation { argv: [String], environment: [String: String] (additions), stdoutIsAnswer: Bool, stdin: closed }`.
The prompt is one argument (never a shell string). After placeholder expansion the argv is exactly:

- codex: `[exe, "exec", "--ignore-user-config", "--disable", "hooks", "-s", "read-only", "--skip-git-repo-check", "-o", <answerFile>, "-m", <model>, <prompt>]`
- claude: `[exe, "-p", <prompt>, "--model", <model>, "--setting-sources", "user", "--strict-mcp-config", "--permission-mode", "plan"]`, `stdoutIsAnswer: true`
- opencode: `[exe, "run", "--model", <model>, <prompt>]`, `stdoutIsAnswer: true`; the run directory is the working
  directory, and the adapter writes `<runDirectory>/opencode.json` denying edit, bash, webfetch and external
  directories (`{"permission": {"edit": "deny", "bash": "deny", "webfetch": "deny", "external_directory": "deny"}}`)
  and sets `OPENCODE_CONFIG=<runDirectory>/opencode.json`.
- hermes: `[exe, "chat", "-q", <prompt>, "--model", <model>]`, `stdoutIsAnswer: true`
- ollama: no process: the broker POSTs `{endpoint}/api/chat` with `{"model": <model>, "messages": [...], "stream": false}`
  and the answer is `message.content`; `options.num_predict` is the seat's `cap.tokens` when set.
- gemini, aider, goose: not adapted in 0.1.0: `failed: <kind> has no adapter`.

Each adapter declares `enforces: Set<Policy>` (`readOnlyFiles`, `noNetworkTools`, `noFurtherMCP`); in U6a the
declaration exists and is tested, U6d consumes it.

### Ask, result, threads

Broker op `ask {target, question, files?, thread?, wait_seconds?, as?}`:

- `as` overrides the caller id only when the connection's `caller` is `owner` (the CLI); an MCP caller cannot
  rename itself.
- Resolution runs; on refusal the reply is `{ok:false, exit, error}` with the exact reason, and the ledger gets a
  `requests` row marked refused. No `runs` row, no process.
- On success a thread id `th_<ulid-like 16 hex>` is created, a `runs` row, a seat run is spawned through the same
  launch machinery as U5 (own process group, reservation, TERM then KILL), with the prompt built as
  labelled evidence: `QUESTION:` then the question, then each `--file` as `FILE <path>:` and its text (files over
  64 KB are cut with a marker; unreadable files refuse the call with exit 64 before anything runs).
- The call waits up to `wait_seconds` (default 120, `0` returns at once); on completion replies
  `{ok:true, data:{state:"answered", thread, answer, seat, substituted:<text or null>}}`; on timeout
  `{state:"pending", thread}` and the CLI exits 2; a seat that ran and failed gives `{state:"failed", reason}` and
  exit 4.
- `result <thread> --wait n` returns the same shapes; an unknown id exits 64 (existing behaviour).
- Follow-up: `ask <seat> <question> --thread <id>` reaches the thread's seat (a different seat name than the
  thread's is a usage error, exit 64). When the adapter supports resuming (none does in U6a), it resumes;
  otherwise the prompt is the transcript so far, `ASKED:` and `ANSWERED:` pairs in order, then the new question.
  The thread keeps every exchange in the ledger.
- A thread's seat is chosen once; a follow-up re-checks the route and the harness but keeps the thread's
  substituted seat when the original is still unusable.

### Stub harnesses in tests

Tests put executables named after the harness kind (`codex`, `claude`, ...) in a temp directory placed first in
the broker's `PATH` (`AGENCIL_PATH_PREFIX`, read by discovery only when `AGENCIL_HOME` is set, which production
never sets in a way that matters because a test seam is only honoured under an explicit
`AGENCIL_TEST_SEAMS=1`). Stubs record their argv and stdin state to a file named by `STUB_RECORD`, answer on
stdout or in the `-o` file, and take their behaviour from `STUB_MODE`.

## U6b contract (chains)

Fills `Resolution.attribute`. Everything below is checked by the broker before resolution picks a process, after the
route check names the route (the route supplies `hop_limit`).

### Capability

- Every seat the broker launches for an ask gets `AGENCIL_CAP=<64 lowercase hex>` (256 random bits) added to its
  environment. The ledger stores only a SHA-256 hash of it (table `capabilities`: hash, thread, exchange seq, seat,
  chain JSON, launch id). It is live exactly while that exchange is `asking`.
- The CLI and `agencil mcp` read `AGENCIL_CAP` from their environment and send it as `cap` on every request.
- Ollama seats have no process, so they never ask anything and get no capability.

### Attribution (what a request is)

The broker reads the peer pid of the socket and walks parent pids until it finds a pid that is a tracked seat
launch's leader or a member of its process group (matched by pgid, start time checked), or until pid 1.

| Process tree | `cap` field | Outcome |
|--------------|-------------|---------|
| descends from a live seat run R | absent | child of R (environment stripped is still attributed) |
| descends from a live seat run R | live cap of R | child of R |
| descends from a live seat run R | live cap of another run | `refused: capability does not match caller` (exit 3) |
| descends from a live seat run R | unknown or ended cap | `refused: capability expired` (exit 3) |
| no seat ancestor | absent | a new root: the claimed caller (`owner`, `as`, the MCP `--caller`) applies as in U6a |
| no seat ancestor | any cap | `refused: capability does not match caller` if live, `refused: capability expired` if not |
| peer pid unreadable, or the walk fails | any | `refused: ancestry unknown` (exit 3), never a root |

A request attributed to a seat run ignores the caller id it claims (`owner`, `as`, `--caller`): the caller for
routing is the parent seat's name, else the parent seat's harness kind, else `any` (same precedence as U6a, so a
route may list a seat name or a harness kind). A seat can therefore not impersonate the owner.

Fault injection: with `AGENCIL_TEST_SEAMS=1`, the broker environment variable `AGENCIL_TEST_FAIL_ANCESTRY=peer`
makes the peer-pid read fail and `AGENCIL_TEST_FAIL_ANCESTRY=walk` makes the parent walk fail, for every ask.

### Chain, hops, cycles

- The chain of a run is the seat names from the root seat to the run's own seat, e.g. `["codex-a","claude-b"]`. A run
  started by a root (owner or detached process) has chain `[seat]`.
- Hop count of a request attributed to a seat run = length of that run's chain (the seats already in the chain; the
  new call is the next hop). Refused when that count exceeds the matched route's `hop_limit`: `refused: hop limit`
  (exit 3). With `hop_limit` 2: owner asks A (chain `[A]`), A asks B (count 1, ok, chain `[A,B]`), B asks C (count 2,
  ok, chain `[A,B,C]`), C asks anyone (count 3): refused.
- Cycle: after resolution, when the resolved seat (including a substituted fallback) is already in the chain:
  `refused: cycle a -> b -> a` (chain names joined with ` -> `, then the target seat), exit 3, at any hop limit; it is
  checked before the hop limit. Nothing runs, a refused `requests` row is written, no thread is created.
- A follow-up (`--thread`) on a thread started by a chained run keeps that thread's chain; its caller must still be
  attributed the same way.
- The `ask` reply and `result` data gain `chain` (array of seat names ending in the answering seat).

### Replay

A capability stops being valid when its exchange leaves `asking` (answered, failed, stopped, timed out). A call that
presents it afterwards, from any process, gets `refused: capability expired`.

### MCP and CLI

Stub seats reach the broker through the real `AgencilCLI ask` and through `AgencilCLI mcp` (JSON-RPC over stdio,
`tools/call` `ask`, with `agent_access` on in config). Both are bounded exactly alike.

## U6c contract (budgets and capacity)

Fills `Resolution.reserve` (step 5, budget part). Black-box observable through the broker ops and the ledger as
described; no Swift API is assumed by tests.

### Config (new keys, each JSON text like `seats`; invalid -> `failed: config <key> is invalid: <problem>`)

- `seats[].price`: optional `{"input_per_mtok": number >= 0, "output_per_mtok": number >= 0}` (dollars per million
  tokens). An `ollama` seat without a price has price 0/0.
- `budgets`: array of `{"name": str (unique), "scope": "route"|"root"|"vendor", "key": str, "window": "run"|"week"|"lifetime",
  "dollars": number?, "tokens": int?, "hard": bool}`. `route`: key is the route target as configured (the requested name
  before alias resolution); `root`: key is the root caller id of the chain (the owner caller, or a root process caller id);
  `vendor`: key is a harness kind, window normally `week` (weeks start Monday 00:00 UTC). At least one of `dollars`
  and `tokens`. A request falls under every budget whose scope and key match. No budgets configured = nothing to
  reserve against, never an error.
- `limits`: object `{"seats_at_once": int 1...16 (default 4), "process_cap": int (default seats_at_once + 4),
  "memory_floor_mb": int >= 0 (default 0)}`. Read on every ask like the other keys.

### Bounded and unbounded seats

A seat is bounded only when it makes exactly one model request: `ollama` seats. Every process seat (claude, codex,
opencode, hermes) is unbounded in 0.1.0. Worst case of a bounded seat =
`utf8 byte count of the final prompt / 1e6 * input_per_mtok + max_tokens / 1e6 * output_per_mtok` dollars and
`prompt bytes + max_tokens` tokens, where `max_tokens` is the seat's `cap.tokens`, or 4096 when unset; the request
carries `options.num_predict = max_tokens` (U6a). An unbounded seat's reservation is its estimate: dollars 0 and tokens
`prompt bytes / 4 + 4096`, seconds `cap.seconds`.

### Admission (all before any spawn or request, fail closed)

In this order, each a refusal with exit 3 and the reply text exactly:

1. `refused: busy` when the number of live seat processes (running or parked) is at `process_cap`. Never waits.
2. `refused: budget` when, for any matching budget, `hard` is true and the seat is unbounded and the budget has a
   `dollars` limit; or when `spent + reserved + this reservation` would exceed a hard `dollars` or `tokens` limit
   (tokens compare against the reservation's tokens; an unbounded seat's token estimate counts for a hard `tokens` limit).
   An estimated (`hard: false`) budget never refuses; it records `estimated`.
3. `refused: memory` when free memory (pages free + inactive, in MB) is under `memory_floor_mb`. Test seam: with
   `AGENCIL_TEST_SEAMS=1`, `AGENCIL_TEST_FREE_MEMORY_MB=<n>` in the broker environment replaces the measured value.
4. Seats at once: when the number of running, unparked seats is at `seats_at_once`, the request waits up to its
   `wait_seconds` (default 120) for a slot, then `refused: busy`. `wait_seconds` 0 refuses at once.

Refusals 1 to 3 write a refused `requests` row, no `runs` or `reservations` rows, and run nothing. Reservation and the
comparison happen in one ledger transaction (`BEGIN IMMEDIATE`), so two concurrent asks over a budget that fits one:
exactly one succeeds and the other is `refused: budget`. A fallback is admitted separately, with its own reservation,
before it spawns; a substituted seat that is refused at admission makes the next fallback be tried, and when none is
admitted the original failure stands.

### Parked ancestors

A seat run is **parked** while it has a child exchange (a nested ask it made, attributed by U6b) in `asking`. Parked
runs hold no "seats at once" slot but do count against `process_cap`. With `seats_at_once` 1 the chain A asks B asks C
completes.

### Reconciliation

- A reservation row exists from admission until the run ends and survives a broker restart (released when the run is
  proven closed, as launches are).
- At the end of an exchange the charge becomes the actual usage when reported, else stays the full reservation
  (`estimated, unreported`): process seats report usage by writing `<runDirectory>/usage.json`
  `{"dollars": number, "tokens": int}` before exiting 0 or not; Ollama reports `prompt_eval_count + eval_count` tokens
  and its dollars follow from the price. A report larger than the reservation is capped at the reservation for
  accounting of a hard budget (a bounded seat cannot exceed it; an unbounded one is charged `max(report, reservation)`
  only on estimated budgets).
- A chain charges every exchange to the root's budgets (`scope: root`) cumulatively, and to the budgets of each
  exchange's own route and vendor.

### Observability

Broker op `budgets` (CLI `agencil budgets [--json]`): `data.budgets` = array of `{name, scope, key, window, hard,
dollars_limit, tokens_limit, spent_dollars, spent_tokens, reserved_dollars, reserved_tokens}`. The ask/result data gain
`reserved` = `{dollars, tokens, seconds}` and `cost` = `{dollars, tokens, basis: "reserved"|"provider"}` once finished.
