# Agencil agent API: CLI, MCP and routing

The contract other agents rely on. Changing a field or an exit code breaks every agent that learned it:
add fields freely, never remove or repurpose one without bumping `api` in the envelope.

## Words

- **Harness**: an installed agent CLI. Known kinds:
  - `claude`, `codex`, `opencode`, `hermes`, `gemini`, `aider`, `goose`.
  - `ollama` (direct, no harness: a plain chat completion).
  - The catalog is data (`Sources/AgencilCore/Harness/catalog.json`), so a new kind is a data change plus an adapter.
- **Seat**: a named, owner-configured target, e.g. `codex-gpt`, `hermes-qwen`, `opencode-kimi`, `claude-opus`, `box-qwen3` (Ollama on a remote box). A seat holds:
  - The harness kind and model, plus an endpoint for Ollama or a provider.
  - A pinned model version, a role (finder, skeptic, synthesizer, answerer), the hardening flags and a per-call cap.
- **Council**: a named set of seats with rules (quorum, rounds, verdict rule, recusal, caps, residency). A one-seat council is an **ask**.
- **Route**: who may reach what. It holds:
  - A caller: a harness kind, a named caller id, or `any`.
  - A target: a seat, a council, or an alias such as `reviewer` that resolves to one.
  - Limits: hop limit, rate, quiet hours, budget, and fallbacks.
  - No route means refused.
- **Thread**: one ask and its follow-ups, kept so a follow-up continues the same conversation.
- **Sitting**: one run of a council of two or more seats.

## Who runs the work

One broker per Mac owns the ledger, the budgets and the concurrency cap:
- The broker is the Agencil app. `agencil serve` runs the same engine headless, for a Mac without a logged-in UI.
- The CLI and the MCP server are thin clients. They speak JSON lines over a Unix socket (mode 0600, owner only): the CLI on `~/.agencil/agencil.sock`, the MCP server on the agent door `~/.agencil/agent.sock`, which serves only `ping`, `ask`, `wake`, `result`, `status`, `stop` and `list_targets`.
- With no broker running, every client command exits 3 with `agencil: Agencil is not running (open the app or run agencil serve)`. Clients never run seats themselves, so two MCP sessions can never double-spend a budget.

## Resolution (a target to a working process)

`ask hermes-qwen` resolves in this order. Each step fails closed with a reason the caller sees:

1. **Route check.**
   - The caller id and its chain (below) must match a route to the target; else `refused: no route from <caller> to <target>`.
2. **Seat lookup.**
   - The target must be a configured seat or an alias; aliases resolve through the route.
3. **Harness install.**
   - Agencil uses the newest detected install of the seat's harness kind: the path, a version within the seat's pin, the signed-in state, and a probe younger than 10 minutes (else it probes now, at most 20 s).
   - None usable: the route's fallbacks are tried in order and the substitution is recorded on the thread (`answered by opencode-kimi, fallback for hermes-qwen: hermes not signed in`).
   - With no usable fallback: `failed: <reason>`.
   - **Preflight standing** (docs/U25-SPEC.md): a seat whose latest probe is younger than 10 minutes and not `ok` is
     unusable without a new process: `failed: <seat> preflight: <reason>[ until <text>]`, reasons `not_installed`,
     `not_logged_in`, `usage_limit`, `no_credit`, `model_unavailable`, `busy`, `unreachable`, `timeout`, `error`. `wake`
     probes every seat of the council first and refuses before any row is written when a slot cannot be filled by an
     `ok` spare of a new vendor. The `preflight` op (`seats`, `probe`) answers from the cache for any local caller;
     probing needs the owner. Seats have a `plan` (`subscription`, `credit`, `free`, `local`); a `free` seat is never
     refused by, nor charged against, a dollar budget. At most one opencode process runs at a time.
4. **Model and endpoint.**
   - For an Ollama-backed seat, the endpoint must answer `/api/tags` and list the model, else `failed: <endpoint> down` or `model not loaded`.
   - A hosted seat needs its key present in the Keychain.
5. **Residency and budget.**
   - Residency is checked against the resolved seat, fallbacks included.
   - The reservation (below) must succeed.

The resolved seat is spawned with the harness adapter's hardened argv. Each adapter has a required test,
with stdin closed and output written to a file:
- `codex exec --ignore-user-config --disable hooks -s read-only`. On a repo copy Codex's own sandbox cannot start inside the broker's, so the seat runs with `-s danger-full-access` under the broker's profile, whose only network is a loopback proxy that connects to the model vendor's hosts and nothing else (docs/U38-SPEC.md).
- `claude -p` with user settings only, strict MCP and the sandbox forced.
- `opencode run` from inside the run's worktree. OpenCode's external-directory rule is a permission prompt, not OS isolation, so the adapter writes a per-run OpenCode config that denies edit, bash, webfetch and external directories, and verifies it took effect with a probe before the first real run. If it cannot, the adapter refuses hosted runs.

Every adapter declares what it enforces: read-only files, no network tools, no further MCP. A route or
council that needs a policy the adapter cannot enforce is refused.

## Chains, hops and loops

Any agent may ask any seat its routes allow, in any direction (Codex asks Hermes, Hermes asks Claude).
Ancestry is established two independent ways, and loops are bounded mechanically:

- **Capability.**
  - Every spawned seat gets `AGENCIL_CAP=<token>`: a random 256-bit token, bound in the ledger to its run, its seat and its ancestry, and valid only while that run is live.
  - The adapter forwards it explicitly to the seat's Agencil MCP server for that run (per-run config override or the harness's env-forwarding setting, verified per adapter in U6). The CLI reads it from the environment.
  - A call presenting a capability that does not belong to a live run, or that belongs to a different run than the process tree shows, is refused.
- **Process tree.**
  - The broker reads the caller's pid from the socket (`LOCAL_PEERPID`) and walks the parent chain. When the caller descends from a seat process Agencil spawned, the call is that seat's child, whether or not the capability arrived.
  - So a harness that drops the environment cannot reset the chain.
  - If the peer pid cannot be read or the parent chain cannot be walked (permission error, a process that exited mid-walk, a pid reused with a different start time), the call is refused (`refused: ancestry unknown`). It never becomes a root.
- **Hop limit**: the chain length must stay at or under the route's hop limit (default 2, maximum 4), else `refused: hop limit`.
- **No cycles**: a target whose seat already appears in the chain is refused (`refused: cycle claude-opus -> codex-gpt -> claude-opus`).
- **No replay**: a capability is useless once its run ends.

**Agent door, access and ownership.** With agent access off the broker refuses every agent call with `refused: agent access is off`. A thread can be followed, read or stopped only by the caller that asked it (`refused: not your thread`); a sitting can be stopped only by the caller that woke it, and read by anyone with access on, which is what an `agencil://sitting/<id>` link is for. Files and a repo named by a non-owner caller must lie inside the git repository of the caller's working directory and outside credential folders (`refused: file outside the caller's repo`).

**Confined seats and the socket.** A seat that works on a repo copy runs in a sandbox that cannot connect to the
broker's socket, so it cannot call Agencil back; a chain starts from a seat that was asked without a repo, or from
your own agents. A process descended from any seat is refused on every operation except `ping`, `register`, `ask`,
`wake`, `result`, `status`, `stop` and `list_targets`, and the `launch` operation is served only by a test broker.

Caller identity is for routing, accounting and loop control, not a security boundary against other software
running as the same macOS user. A same-user process that detaches from a seat's process tree and discards
its capability looks like a new root; it is still limited by root rate limits and budgets. The MCP server
is off by default, and routes default to refuse.

## Budgets and capacity

- **Reservations.**
  - Before any spawn (first try, retry, fallback, each round), the broker reserves the run's declared cap (dollars, tokens, seconds) in one `BEGIN IMMEDIATE` transaction against every budget it falls under: route, council, vendor week, and the chain root.
  - The spawn happens only after the commit.
  - On exit the reservation is reconciled to the actual cost.
  - Reservations survive a broker restart and are released only when the process is proven dead.
- **Chains** charge cumulatively to the root's budget.
- **Hard and estimated caps.**
  - A cap is `hard` or `estimated`, set per budget.
  - A seat may serve a hard dollar cap only if it is **bounded**: its worst-case cost is known before the spawn, and the reservation is that worst case. Killing a process mid-stream is never the enforcement, because input already sent and tokens already generated are billed.
  - Two kinds of seat are bounded:
    - **Single-call seats** (Ollama, an OpenAI-compatible endpoint, any adapter that makes exactly one model request). Worst case = prompt bytes x input price + `max_tokens` x output price. The byte count bounds the input tokens, since a token is at least one byte. `max_tokens` is set on the request.
    - **Agentic harnesses** that enforce a dollar spend limit themselves (a budget flag that stops the run at a stated amount), verified by the adapter probe against a stub provider. Worst case = that limit. A turn limit alone does not bound cost, because each turn's input grows, so it never makes a seat bounded.
  - Every other seat is **unbounded**: refused on hard caps, allowed on estimated caps only.
  - In 0.1.0 none of the hardened argv above (claude, codex, opencode, hermes) carries a verified dollar-stop flag, so all agentic seats are unbounded. Hard dollar caps apply to single-call seats only; agentic seats get estimated dollar caps and a hard time cap (process-group kill). An adapter becomes bounded only when its probe verifies such a flag.
  - A bounded seat cannot spend past its reservation, so a hard cap holds even when usage is never reported.
  - Local Ollama seats have a price of 0 and use time and token caps.
- **Reconciliation.**
  - On exit, the reservation becomes the actual cost when the harness reported usage (`provider`).
  - When it did not, the reservation stays charged in full (`estimated, unreported`); the charge is never lowered for missing data.
  - The sum of charges against a hard cap therefore never exceeds the cap. An estimated cap may be exceeded, and the Budgets pane and the run say so.
- **Capacity.**
  - "Seats at once" counts running seats.
  - A seat that is waiting on a nested ask it made is **parked** and does not hold a slot, so a chain cannot deadlock at a cap of 1.
  - A separate process cap of seats at once plus the maximum hop limit bounds parked processes.
  - A request that would exceed it is refused at once. A request that can run later waits up to its `wait`, then `refused: busy`.
- **Memory floor**: no seat starts while free memory is under the floor set in General.

## CLI

`agencil <verb> [options]`. Every verb takes `--json`, which prints one envelope:

```
{"api": 1, "source": "agencil", "generated_at": "2026-...Z", "data_note": "...", "data": { ... }}
```

| Verb | What it does |
|------|--------------|
| `ask <seat-or-alias> <question> [--file <path>]... [--thread <id>] [--wait <s>] [--as <caller-id>]` | One-seat council. Default wait 120 s. On timeout returns `pending` with the thread id |
| `result <thread-or-sitting-id> [--wait <s>]` | The answer or the verdict, waiting up to `wait` |
| `wake <council> --brief <file> [--file <path>]... [--repo <path>] [--diff <range>] [--wait <s>] [--synthesize]` | Starts a sitting. A council with a synthesizer ends with a written Markdown summary (`summary`, `summary_by` in the result); `--synthesize` (`synthesize: true`) asks for one from a council that has none, written by its first answering seat that can run, best-effort and never changing the verdict (`summary_fallback: true`). The owner (no `--as`, outside every seat) needs no route to the council; an agent does. `--file` attaches up to 8 absolute-path files: text (64 KB each) that every seat reads as evidence, and images (PNG, JPEG, GIF or WebP, 10 MB each, 20 MB in all) that claude and codex seats see natively; any other seat is told an image was attached and not shown, and the brief lists them as `images_not_shown`. `ask --file` takes text only. The brief must name a change kind, a question and, for code, a diff range, or the call exits 64 |
| `status <id>` | State, seats, elapsed time, cost |
| `stop <id>` | Stops a thread or sitting; seats are killed by process group |
| `seats`, `councils`, `routes`, `triggers` | The configuration, read-only. `triggers` also shows each trigger's last fire and sitting (docs/U7-SPEC.md "Triggers") |
| `seats presets`, `seats add --preset <name>` | The documented seat catalog (docs/U25-SPEC.md "Presets") and adding one through the validated config path; 64 for an unknown preset, 4 for a refused draft |
| `preflight [--seats a,b] [--probe]` | Each seat's standing (`<name>  <reason>  <detail>`): cached without `--probe`, probed now with it (owner only). Exit 0 when every listed seat is `ok`, else 4; an unknown seat exits 64 |
| `followup` (op, panel only; no CLI verb, no MCP tool) | `{sitting, question, seat?}`: the owner asks a seat of a finished sitting's council more, from the sitting's page (U30). Refused `refused: a follow-up comes from the panel` (exit 3) from any other process, `as` or seat child. The seat gets the sitting's record as labelled evidence (the question, the synthesis, each seat's last answer, the verdict) and the owner's text; later follow-ups to the same seat continue its thread. Replies at once with `{sitting, thread, seat, seq}`; read the answer with `detail` |
| `detail <thread-or-sitting-id>` | CLI only, read-only: a thread's whole exchange (`caller`, `seat`, `model`, `harness`, `project`, `exchanges[]` with `question`, `answer`, `state`, `reason`, `cost_usd`, `tokens`), or a sitting's `brief`, `project`, `change_kind`, `question`, `diff_range`, `repo`, `snapshot`, full `verdict` (reasons, votes, claims) and `rounds[]`, each with its seats' `answer`, `state`, `reason`, `started`, `ended`, `model`, `harness`, `cost_usd`, `tokens`. Each exchange and seat also carries `tokens_in`, `tokens_out`, `tokens` (their sum), `cost_usd` and `cost_note` (`reported`, `estimated` or `estimated, subscription`) when the harness reported usage in its JSON output or the seat wrote `usage.json` (docs/U6-SPEC.md); the fields are absent otherwise, and a reservation charged in full is not a report, so the panel says unknown. `project` is the asking agent's git top-level folder name and path (home as `~`), captured from the working directory by the CLI or `agencil mcp` on `ask` and `wake`, kept in the local ledger only; absent when not recorded. A sitting also carries `summary`, `summary_by` and `summary_fallback` when its council wrote a synthesis (U29), `followups[]` (the owner's follow-up threads: `seat`, `thread`, `model`, `harness`, `exchanges[]` with the owner's own `question`, `answer`, `state`, usage as above), `follow_up_seats` and `follow_up_default` (U30). Text fields are cut at 32 KB. The panel's detail screens read it; no MCP tool |
| `panel` | CLI only, read-only: the snapshot the app panel shows (threads, sittings, findings, seats, week spend); no MCP tool (docs/U8-SPEC.md) |
| `costs [day]` (op; CLI only, read-only, no MCP tool) | What every answered seat call on this Mac has cost (U31). `{rows[], now}`: one row per local day, `project`, `council` (`direct` for an ask outside a sitting), `seat`, `model`, `caller`, with `calls`, `unpriced` (answered calls with no recorded cost, counted and never priced) and `cost` (dollars). With `day` (`YYYY-MM-DD`, the machine's local calendar) it also returns `entries[]`, that day's calls newest first (200 at most): `thread`, `sitting?`, `seat`, `model`, `caller`, `project`, `council`, `cost?`, `tokens_in?`, `tokens_out?`, `at`. A malformed `day` is exit 64. Costs are the harness-reported or estimated figures of docs/U6-SPEC.md and survive the retention prune. The Costs pane in Settings reads it || `harnesses [--probe]` | Detected harnesses: path, version, signed in, chain support, last probe |
| `models` | Providers and Ollama endpoints with health and models |
| `findings [--open]`, `dispose <claim-id> confirm|dismiss|will-fix` | Findings and the owner's disposition |
| `adjudicate <claim-id> [--wait N]` | Asks a seat of an independent vendor to weigh a finding's evidence; the answer is recorded as an adjudication |
| `proposals [--all]`, `learn approve|reject|review <id>`, `learn rollback` | The learn loop's council proposals and the owner's decision on them |
| `leaderboard preview|publish` | `docs/LEADERBOARD.md` |
| `mcp [--caller <id>]` | Runs the stdio MCP server (what harness configs launch) |
| `install-mcp <harness> [--caller <id>] [--dry-run]` | Writes the MCP entry into that harness's config; `--dry-run` prints the diff |
| `install-instructions <harness> [--uninstall] [--dry-run]` | Adds or removes the marked "when to use Agencil" paragraph in that harness's instruction file (docs/U17-SPEC.md); other text in the file is never touched |
| `access [--json]` | How this Mac is wired, per harness: server entry, instruction state, routes, and drift lines; reads files only, no broker || `serve` | The headless broker |
| `version` | Version and the source line |

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | Ok: answered, or verdict `PASS`; a consult council's `AGREED`, `SPLIT` and `ANSWERED` (a split is an answer, not a failure) |
| 1 | Verdict `BLOCK` |
| 2 | Verdict `INCOMPLETE`, or still pending at the end of `--wait` |
| 3 | Refused: no route, hop limit, cycle, budget, busy, broker not running, MCP off |
| 4 | Seat failed and no fallback answered |
| 64 | Usage or a brief missing a required field |
| 70 | Internal error |

Errors go to stderr as `agencil: <message>`. The installer recognizes its own CLI by the `agencil:` prefix
on `agencil version --bad-flag`.

## MCP server

- JSON-RPC 2.0 over stdio, protocol versions 2025-06-18 and 2025-03-26. The server declares the `tools` capability at initialization.
- Schemas: each tool's `inputSchema` and, on 2025-06-18, `outputSchema` are JSON Schema files in `Sources/AgencilCore/MCP/schemas/`, versioned with `api`.
- Results:
  - On 2025-06-18, a result returns the envelope as `structuredContent`, valid against `outputSchema`, plus the same JSON as a text content block.
  - On 2025-03-26 (no structured output), it returns the text block only.
- Size, every field bounded by schema:
  - Caps: `answer` 256 KB, `evidence` 4 KB, `reason` and `why` 1 KB, `question` 64 KB, ids 64 bytes.
  - A longer value is cut at a UTF-8 boundary, and `<field>_truncated: true` is set next to it. The full answer stays in the ledger, readable with `agencil result <id> --full` or the `ask_result` tool with `full: true`, which pages it in 256 KB chunks with `offset`.
  - Lists are then cut from the end until the whole result is under 1 MB, setting `truncated: true`.
  - A truncated result always validates against its schema.
- Errors: a refusal or failure is a tool result with `isError: true` and the envelope (`state`, `reason`). JSON-RPC errors are reserved for protocol faults.
- Off by default: with Agent access off, every tool returns `isError: true`, `refused: Agent access is off in Agencil Settings`.

Unlike MacMax and RMJ, Agencil's MCP has tools that act (ask, wake, stop): acting is the product. Every
acting call:
- passes the route check;
- is limited by budget and rate;
- shows in Threads or Sittings at once;
- is listed under Settings > Agent access, recent calls.

| Tool | Input | Output |
|------|-------|--------|
| `list_targets` | none | The seats and councils this caller has a route to, with health and the route's limits; a council row carries `mode` (`review` or `consult`) |
| `ask` | `target`, `question`, `files?` (paths inside the caller's repo), `thread?`, `wait_seconds?` (default 60, max 600) | `thread`, `state` (`answered`, `pending`, `failed`, `refused`), `answer?`, `seat`, `fallback?`, `cost`, `seconds` |
| `ask_result` | `thread`, `wait_seconds?` | As `ask` |
| `wake_council` | `council`, `brief`, `repo?`, `diff?`, `change_kind`, `author_vendor?`, `uncommitted?`, `wait_seconds?` | `sitting`, `state`, `verdict?` |
| `sitting_status` | `sitting` | Seats, rounds, claims so far |
| `sitting_verdict` | `sitting`, `wait_seconds?` | `verdict`, `claims` (with ids, `file:line`, severity, backers, dissenters, `minority`), `independence` flags |
| `stop` | `id` | `stopped` |

Clients time out tool calls (Claude Code's default is configurable). So the default `wait_seconds` is 60:
a long sitting returns `pending` and the agent polls `ask_result` or `sitting_verdict`.

**Links.** The panel's detail screens have a copy-link button that puts `agencil://sitting/<id>` (or
`agencil://thread/<id>`) on the clipboard. The owner pastes it to another agent, which passes the link, or the bare
id, as `sitting`, `thread` or `id` to any tool above. The link is only the id, an address and not a credential or a
permission. It is not a registered macOS URL scheme and does not open from a browser.

### Configuring local agents (Settings > Agent access)

One card per detected harness:
- The exact config entry Agencil would write, with a "Copy" and an "Install" press. Install shows a diff, writes, then reads the config back to verify.
- A caller id (default: the harness kind) and the routes that caller has.
- What the harness was told: the one-paragraph instruction installed as that harness's rule or skill file, so agents know Agencil exists and when to use it.

Entries (exact syntax verified against each harness's current docs in U6; these are the expected shapes):

| Harness | Entry |
|---------|-------|
| claude | `claude mcp add agencil --scope user -- <home>/.local/bin/agencil mcp --caller claude` |
| codex | `~/.codex/config.toml`: `[mcp_servers.agencil]` `command = "~/.local/bin/agencil"` `args = ["mcp", "--caller", "codex"]` |
| opencode | `opencode.json` `mcp.agencil`: `{"type": "local", "command": ["~/.local/bin/agencil", "mcp", "--caller", "opencode"]}` |
| hermes | Its MCP config, same command and args |
| other | The command line to paste |

- Install creates the entry when absent.
- It refuses when an `agencil` entry exists that Agencil did not write. It replaces only an entry whose hash matches `~/.agencil/installed.json`.
- Writes are atomic under a lock and are read back.
- Uninstall removes the entry only if it is unchanged since install, never anything else in the file.
- A config that does not parse, or a symlink to a file the user does not own, is left untouched and shown as a problem.

## Seat answer contract (councils)

Seats in a council of two or more answer in a fixed JSON shape, validated at ingest; an ask may answer in
prose. The shape:

```
{"claims": [{"id": "c1", "kind": "defect|risk|question|note", "severity": "p0|p1|p2|p3",
  "confidence": 0.0-1.0, "file": "path", "line": 12, "evidence": "quoted snippet", "fix": "..."}],
 "assessments": [{"claim": "<other seat's claim id>", "stance": "support|dispute|abstain", "why": "..."}],
 "vote": "approve|block|abstain", "notes": "..."}
```

- Output that does not parse is retried once with the validator's error.
- A second failure marks the seat `failed: unparsable` and never counts as a vote.
- Agencil assigns global claim ids (`AG-<sitting>-<n>`).
- A commit that fixes a finding names it in its message body (`Fixes AG-41-3`). That records evidence, which adjudication turns into an outcome (`docs/PLAN.md` U11).
- How votes become a verdict: the truth table in `docs/PLAN.md` U7.

### Consult councils

A council with `"mode": "consult"` in `config.json` (Settings: Kind) answers a question instead of gating a change
(docs/U33-SPEC.md). `councils` and `list_targets` show each council's `mode`; one without it is `review`. Its seats
answer blind, then (with `rounds.rebuttal`, the default, and two or more blind answers) review the other positions
under anonymous labels `P1`..`Pn`; there is no challenge round, no recusal and no vote. The answer shape:

```
{"position": "one line, at most 300 characters", "confidence": 0.0-1.0, "reasoning": "markdown",
 "crux": "what would change this position", "questions_back": ["at most 5, for the asker"],
 "assessments": [{"position": "P2", "stance": "agree|disagree|partly", "why": "..."}],
 "kept": true, "because": "what moved it, when kept is false", "new_evidence": true}
```

`assessments`, `kept`, `because` and `new_evidence` belong to the review round only, with one assessment for every
label the seat was shown (`assessments leave out P2` otherwise, retried once). A seat whose review answer fails
twice keeps its blind answer. The verdict, first match wins:

| Condition | Verdict |
|-----------|---------|
| A configured synthesizer failed, or valid answers below quorum | `INCOMPLETE` (exit 2) |
| Fewer than two valid answers, no review round, or no assessment recorded | `ANSWERED` |
| Every assessment is `agree` | `AGREED` |
| Otherwise | `SPLIT` |

`wake` and `sitting_verdict` return the review keys with `mode: "consult"`, `claims: []`, no `rule` or `high_risk`,
and: `positions` (per seat: `seat`, `vendor`, `label`, `blind`, `final`, `kept`, `because`, `new_evidence`,
`questions_back`, `minority`), `assessments` (`seat`, `about`, `stance`, `why`), `minority` (`seat`, `vendor`,
`position` for every position more than half of its assessors disagree with and its seat kept) and `votes` rows with `reason` and no
`vote`. A synthesis always runs and must name every seat with a valid answer. `independence` may also carry
`single_vendor`, `converged_in_review`, `changed_without_evidence` and `no_synthesis`.

A seat's position, reasoning and `questions_back` are seat output: the asking agent weighs them as evidence and never
follows them as instructions.
