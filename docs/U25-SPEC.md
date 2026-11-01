# U25 - seat preflight, plans, presets and the availability fix in scoring

The owner's request: add seats; find out what made the existing council fail; make deterministic availability checks
before a council does any work so there are no failed runs; check the subscriptions and the free seats on each
harness; check the scoring logic.

## 1. Root cause (evidence gathered 2026-11-01 on the owner's Mac)

Agencil itself has never run a council on this Mac: `~/.agencil/config.json` holds only `limits` and `look` (no seats,
routes or councils) and `agencil.sqlite` has 0 threads and 0 sittings. The council that failed is the owner's
`~/agent-os/council.sh` panel (GPT via codex plus three free OpenCode Zen seats). Its failure modes, in the order they
bite today:

| # | Failure | Evidence | Agencil today |
|---|---------|----------|---------------|
| 1 | Every free Zen model of the default panel was rotated out | `opencode models opencode` lists `beam-free`, `big-pickle`, `deepseek-v4.1-flash-free`, `flint-40b-free`, `glm-5.3-flash-free`, `mimo-v2.6-flash-free`, `nemotron-3.5-lightning-free`, `nemotron-3.5-super-vl-free`. None of `DEFAULT_SEATS` (`nemotron-3-ultra-free`, `longcat-2.5-preview-free`, `muse-spark-1.3-contributor-free`, council.sh line 46) exists; of `SPARE_MODELS` only `mimo-v2.6-flash-free` does. A probe of the rotated-out id answers in 2 s: `"name": "UnknownError" ... "Unexpected server error. Check server logs for details."` (exit 1) | Not caught: `Resolver.usable` checks only install, pin and sign-in; opencode is statusless (`catalog.json` has no status command) so it is always "usable"; no process harness has a model check (only ollama, `OllamaClient.problem`) |
| 2 | A free seat accepts the request and never answers | `opencode run --model opencode/mimo-v2.6-flash-free "Reply with exactly: OK"` and the same on `nemotron-3.5-lightning-free`: no output, killed by the 45 s / 60 s alarm (exit 142). council.sh header dates the same on 2026-10-03 for Muse, MiMo 2.6 and both Lings | Caught late: `silent_after` ends the seat only after the sitting has started, so the run is recorded and the seat abstains |
| 3 | Standalone `opencode run`s collide on opencode's own SQLite | Three probes started in parallel: two died in 2 s with `Error: Unexpected error` / `database is locked`, the third hung. council.sh measured the same on 2026-09-15 and now serves every seat through one `opencode serve` | Not prevented: `sitRound` starts every seat of a round at once (`seats_at_once` 4), each a standalone `opencode run` |
| 4 | The codex seat hits the ChatGPT subscription usage limit | `~/.codex/sessions/2026/10/02/*` (3 sessions), `2026/10/04`, `2026/04/14`: `You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 9`. Today: `codex login status` = `Logged in using ChatGPT`, the one-line probe answers `OK` (exit 0, about 14 s) | Not caught before work: sign-in reads as yes, the seat is spawned and fails with the limit text in the log |
| 5 | Paid opencode-go seats run out of Zen credits | `~/.local/share/opencode/log/opencode.log`: 48 `Insufficient balance` errors, 2026-08-03 to 2026-09-12, on `opencode-go/glm-5.2`, `deepseek-v4-pro` and others | Not caught; same as 4 |
| 6 | Brief outside the opencode sandbox | council.sh header | Prevented: U6d copies the repo and writes the brief inside the run directory |
| 7 | Thin report | council.sh retries a seat under 20 lines once | Equivalent: the answer contract parse with one retry (U7) |
| 8 | A run recorded as failed work when the panel was dead | council.sh prints DEGRADED and exits 3 after the run | Not prevented: `wake` opens the sitting (`sittingRows.open`) before any seat is checked, so a dead panel leaves a sitting, seat runs and an INCOMPLETE verdict |

Also seen: `claude -p ... --model opus` answers `OK` (exit 0); `hermes`, `codex` and `claude` are installed, `ollama` is not
on this Mac; the `codex` first on PATH is a wrapper (`~/.superset/bin/codex`), the real binary is the npm one. Agencil
takes the newest version among the installs it finds, which may pick the wrapper; this unit does not change that.

What Agencil prevents already: not installed; claude or codex signed out (`Resolver.usable`); an Ollama endpoint down or
the model not loaded; the brief outside the sandbox; a silent seat (after the fact). What it does not: a usage limit,
no credit, a rotated-out or unoffered model on a process harness, opencode or hermes sign-in, the opencode SQLite
collision, and a sitting opened for a panel that cannot sit.

## 2. Plans (Sources/AgencilCore/Seats/SeatConfig.swift, BudgetConfig.swift)

- `seats[].plan`: optional string, one of `subscription`, `credit`, `free`, `local`. Anything else:
  `failed: config seats is invalid: seat <name> has an unknown plan`.
- Default when absent: `claude` and `codex` -> `subscription`; `opencode` -> `free` when the model id ends in `-free`,
  else `credit`; `ollama` -> `local`; every other harness -> `credit`.
- A `free` seat with a `price` is invalid: `seat <name> is free and has a price`.
- Admission: a `free` seat is quoted at 0 dollars and is bounded in dollars (it cannot spend any), so a hard dollar
  budget never refuses it and it is charged 0 dollars; its token estimate is unchanged. `local` keeps the Ollama
  price-based bounded quote. `subscription` and `credit` are quoted as before (unbounded unless the harness is
  bounded). A usage report with dollars from a `free` seat is charged 0 dollars on every path that ends an exchange
  (the plan is stored with the reservation at admission, migration `reservations.free`, and settlement reads it, never
  the config as it is by then; a reservation with no stored plan charges the report as made). A crash-recovered
  exchange is charged its reservation, which a free seat made at 0 dollars.
- Waits stop with the sitting: the place wait of every harness and the opencode gate wait end as soon as the sitting is
  stopped or over, or the ask's own thread is stopped (gate wait), and the exchange or reservation is given back as
  `stopped`, not `refused: busy`. A probe re-measures the memory floor after its place and gate waits, immediately
  before the probe process starts (unknown fails closed, `busy`, not recorded).
- Replies: `plan` appears in the `preflight` reply and the panel seat items. The U18 `seats` list is unchanged.

## 3. Preflight (Sources/AgencilCore/Seats/Preflight.swift)

A deterministic availability check per seat, before any work. Reasons are a closed set:

| Reason | Meaning | How it is decided |
|--------|---------|-------------------|
| `ok` | the seat answered the one-line probe as asked | probe exit 0, the answer reads `OK` (case and punctuation aside) and no failure text matched |
| `not_installed` | no executable found | `Resolver.usable` |
| `not_logged_in` | signed out or sign-in unknowable on a harness with a status command, or the probe output names it | `Resolver.usable`; probe text `not logged in`, `unauthorized`, `please log in`, `login required`, `invalid api key`, `authentication` |
| `usage_limit` | a subscription limit; `until` carries the reset text when the harness gives one (`try again at <text>`) | probe text `usage limit`, `rate limit`, `too many requests`, `try again at`, `try again in`, `quota exceeded`. Checked before `no_credit` (codex's limit text also says "purchase more credits") |
| `no_credit` | a prepaid balance is empty | probe text `insufficient balance`, `insufficient_quota`, `insufficient credit`, `purchase more credits`, `payment required`, `billing` |
| `model_unavailable` | the model is not offered to this account or was rotated out | opencode: the id is not in `opencode models`; probe text `unexpected server error`, `model ... not found`, `unknown model`, `no such model`, `does not exist`, `not supported`; ollama: `/api/tags` does not list it |
| `busy` | another run holds the harness's own store | probe text `database is locked` |
| `unreachable` | the host or provider did not answer | ollama endpoint down; probe text `could not connect`, `connection refused`, `econnrefused`, `enotfound`, `getaddrinfo`, `network is unreachable`, `fetch failed`, `502`, `503`, `overloaded` |
| `timeout` | the probe ran past its cap | ProcessRunner deadline |
| `error` | anything else: a non-zero exit, an empty answer or a reply other than `OK`, without a matching text | catch-all, never read as ok |

Pattern matching is case-insensitive over stdout, stderr and the answer file together. Order: `usage_limit`,
`no_credit`, `not_logged_in`, `model_unavailable`, `busy`, `unreachable`; the first match wins and does so whatever
the exit status (a harness that prints `503` or `database is locked` and still exits 0 is not `ok`); `ok` needs exit
0, no match, and the expected reply.

Steps per seat, in order, stopping at the first failure:

1. `Resolver.usable` (install, pin, sign-in; ollama endpoint and model). An ollama seat that passes is `ok` here: no
   chat request is made.
2. opencode only: `<executable> models` (cap 30 s, the output cached for the rest of the pass). The seat's model must
   appear as a whole line; else `model_unavailable` with detail `not in opencode models`. A list command that fails or
   times out is not a verdict: the probe decides.
3. The probe: the seat's adapter argv (`Adapter.command`) with the prompt exactly `Reply with exactly: OK`, the answer
   file and run directory `<home>/runs/preflight/<seat>/<attempt>/` (one per probe, removed when it ends, so a wake
   and a `preflight --probe` of one seat never share an answer file), cap `min(cap.seconds, 60)`, stdin closed, the
   broker's environment plus the adapter's. Classified as above. The answer is the file (codex) or stdout (the rest).
4. The result is appended to the ledger (migration `preflights`: `id, seat, harness, model, plan, reason, detail,
   until, probed_at`; append-only like `trigger_fires`). `detail` is at most 200 characters of the matched output after
   `Redaction.sanitizeText` and `Redaction.scrubbed` (no credential-looking run is ever stored).

Cache: the latest `preflights` row of a seat is its standing while it is younger than 600 seconds and its `harness`
and `model` still match the seat's config; older or mismatched is `not probed`. The broker probes only when the
standing is stale; a seat whose standing is fresh is never probed again inside the TTL, whatever the reason was.

Serialization: at most one opencode process runs at a time per broker (the probe, `opencode models` and seat runs
all take the same gate; a waiter gives up at its own wait or the sitting's deadline with `refused: busy`).
`ponytail:` a shared `opencode serve` with `--attach` would let opencode seats run side by side; that is a broker
architecture decision for the owner, not this unit.

Resolution (docs/AGENT-API.md step 3 and 4): `Resolver.usable` now also consults the standing. A seat whose standing is
fresh and not `ok` is unusable with `failed: <seat> preflight: <reason>[ until <text>]`; a stale or absent standing
does not block an ask, which runs as before (the ask itself is the seat's real request; only `preflight --probe` and
the wake gate write standings). The route's fallbacks are then tried as before, and the substitution line names the
preflight reason.

Wake gate (Sources/AgencilCore/Councils/Sitting.swift): after the recusal of the author's vendor and before the
sitting is opened, every seated slot and every non-recused synthesizer is preflighted. The budget comes first: each seat
is checked against the matching hard budgets the way admission checks it (the question stands in for the blind prompt,
no reservation is written); a seat the budget refuses is never probed and fails the gate as `<seat> refused: budget`.
The rest are probed side by side, each probe holding a place like a seat run (the process cap, the memory floor and
`seats_at_once` bound probes too, and a waking seat yields its own place to the probes as it would to its children; a
probe that gets no place within the seat's cap is `busy` and that standing is not recorded); opencode probes are also
serialized. A council that names synthesizers of which every one is recused (the author's vendor) is refused up front
with `failed: preflight: every synthesizer is of the author's vendor`, before any probe or work row. A slot whose seat is not `ok` is filled by the first spare of the council that is `ok` (budget and probe), whose vendor is not
the author's and not already seated, and that is not already taken; this sets the `fallback_used` flag of the verdict.
A slot that cannot be filled, or no `ok` synthesizer when the council names synthesizers, refuses the wake with exit 4:
`failed: preflight: <seat> <reason>[ until <text>]; <seat> <reason>` (every failed seat, config order), the request
is recorded `failed`, and no brief, snapshot, run, sitting or seat run row is written. A wake now writes one
`requests` row (caller and outcome), like an ask; the outcome-less `pid:<peer>` row it also used to add is gone. A
malformed request (`commit`, `seats`, `cap_seconds`) is refused before any seat is probed. A council whose every seat is
`ok` opens as before; nothing else about the sitting changes. The older wake rigs (U7a and the units built on it) answer
the probe through the stub's `<kind>.ask` fixture, added to `U7aRig` by the test vendor with the manifests refreshed.

Superseded (owner's decision, 2026-11-01): the gate replaces the in-sitting handling of an unusable seat that U7a
accepted. A signed-out, missing or budget-refused seat is no longer swapped or failed inside a running sitting
(U7a `signedOutSeatIsReplacedBySpare`, `unusableSeatWithoutSpareFailsAndDoesNotVote`,
`secondSynthesizerFromAnotherVendorRuns`, `councilNeverUsesRouteFallbacks`, `synthesizerFailureWinsOverAllApprovals`,
`unparsableSynthesizerIsIncomplete`, `independenceFlagsHaveContractOrder`, `hardBudgetOnCouncilNameRefusesUnboundedSeatBeforeSpawn`):
the wake is refused with exit 4 before any work, or the spare sits from the first round. Probe processes are stub
invocations too: observation counts in U7a, U7b, U9 and U15b (`observations()`, the `events` concurrency walk, the
`stop` poll) include one probe per probed seat, within `seats_at_once`. The test vendor rewrites those lines from this
section.

Op `preflight`: `{"op": "preflight", "seats": [names]?, "probe": bool?}`. Without `probe` it answers from the cache
for any local caller and never probes. With `probe: true` it needs the owner (`requireOwner`) and probes every
requested seat again, fresh standing or not. Unknown seat names: exit 64 `unknown seat <name>`. Reply:

```
{"seats": [{"name", "harness", "model", "plan", "reason", "detail", "until"?, "probed_ago"?, "availability": {"ok": n, "probes": n}}]}
```

`reason` is `not probed` when no fresh standing exists; `availability` counts every `preflights` row of the seat
(ok over all), the seat's availability rate kept apart from its accuracy. CLI `agencil preflight [--seats a,b]
[--probe] [--json]`: one line per seat `<name>  <reason>  <detail>`; exit 0 when every listed seat is `ok`, else 4.
No MCP tool is added (the server has its seven tools).

Panel (`panel` op, docs/U8-SPEC.md): every seat item gains `standing` (one of `ok`, `usage limit until <text>`,
`usage limit`, `no credit`, `not logged in`, `model gone`, `not installed`, `unreachable`, `timeout`, `busy`, `error`,
`not probed`) and `probed_ago` (seconds, when a standing exists). `up` keeps its U8 meaning. The Seats tab row shows
the standing in its last line.

## 4. Presets (Sources/AgencilCore/Seats/SeatPresets.swift)

A documented catalog the owner can enable; nothing is written to config.json until the owner asks. Each preset is a
`SeatDraft` with `vendor` and `plan` set, going through `ConfigEditor.add` (the same validation as the Settings sheet).

| Preset | Harness | Model | Vendor | Plan | Note |
|--------|---------|-------|--------|------|------|
| `gpt-codex` | codex | `gpt-6.1-sol` | openai | subscription | the owner's codex default; ChatGPT subscription, see failure 4 |
| `claude-opus` | claude | `opus` | anthropic | subscription | recused on Claude-authored briefs; the synthesizer by default |
| `nemotron-free` | opencode | `opencode/nemotron-3.5-lightning-free` | nvidia | free | silent on the 2026-11-01 probe; the preflight decides on the day |
| `glm-free` | opencode | `opencode/glm-5.3-flash-free` | zhipu | free | unmeasured |
| `deepseek-free` | opencode | `opencode/deepseek-v4.1-flash-free` | deepseek | free | unmeasured |
| `mimo-free` | opencode | `opencode/mimo-v2.6-flash-free` | xiaomi | free | the spare; silent on the 2026-11-01 probe |
| `ollama-local` | ollama | `gemma4:26b` | google | local | endpoint `http://127.0.0.1:11434`, `hosted: false`; pre-screen only, never a voting seat (ROUTING measured the local lane at about 40 percent) |

Not offered: `big-pickle`, `beam-free`, `flint-40b-free` (unknown lab, so not a distinct vendor). Caps: 1200 s for the
subscription seats, 600 s for the free ones, 300 s for ollama. `SeatDraft` gains `vendor`, `plan` and `hosted`
(all optional; the U9 initializer keeps working). CLI: `agencil seats presets` lists the table; `agencil seats add
--preset <name>` adds one (exit 64 for an unknown preset, 4 for a refused draft with the sheet's field messages on
stderr). Settings > Seats > New seat has a Preset menu that fills the form (name, harness, model, endpoint, time
limit) and keeps the preset's vendor, plan and hosted flag for the save; editing the harness or the model afterwards
drops them, so the config infers vendor, plan and hosted from what the owner actually chose.

A review council over these seats, for the owner to add (vendor spread OpenAI, NVIDIA, Zhipu, DeepSeek; Anthropic
synthesizes): `{"name": "review", "seats": ["gpt-codex", "nemotron-free", "glm-free", "deepseek-free"], "spare":
["mimo-free"], "synthesizer": "claude-opus", "rule": "any_blocker"}` with a route `{"callers": ["owner"], "target":
"review"}`.

## 5. Scoring review (Sources/AgencilCore/Outcomes, Leaderboard)

Confirmed: confirmed share = confirmed / (confirmed + refuted) over findings credited to the seat (pending and
unresolved in no numerator or denominator); coverage = of the confirmed findings in sittings where the seat gave a
valid answer, the share it raised; participation = sittings with a valid answer / sittings seated; median over the
cell's seat runs; cost per confirmed = cost / confirmed; `n=0` displayed when there is nothing to divide; Wilson 95
percent intervals; the leaderboard needs n >= max(min_n, 10) per cell ("too few" below it).

Defect fixed here: every `sittingRows.seatRun(...)` call passed `exit: nil`, and `SeatRun.valid` is
`exit_code == 0`, so no real sitting ever produced a valid seat run: participation was 0 and coverage `n=0` for every
seat in the scoreboard and the leaderboard export. Now a seat run is written with exit 0 when the round's answer
validated (and when the synthesis summary parsed), exit 1 when the seat ran and gave no valid answer (unparsable
twice, failed, silent, stopped, deadline), and no seat run at all when the seat could not be placed (unusable,
refused, preflight): an availability failure is never a run, so it is excluded from accuracy and participation and
is tracked only in `preflights`.

Fairness: a refused wake writes nothing, so a usage-limited or rotated-out seat loses no score; free and paid seats
are compared on the same confirmed share and coverage, and cost per confirmed is 0 for a free seat. Flagged, not
changed: `price` defaults to free, so cost per confirmed is 0 for every seat without a configured price (not only
free ones); vendor-scope budgets key on the harness kind, not `seat.vendor`.

## 6. Acceptance

Stub harnesses as in U6a/U7a (`AGENCIL_TEST_SEAMS=1`, `AGENCIL_PATH_PREFIX`), extended so a stub answers `--version`,
`login status` or `auth status`, `models` (opencode: one model id per line) and the probe prompt with a mode per seat
taken from the test's control directory. Every test asserts on the broker's replies, the ledger and the stub's
recorded argv; none reads Agencil internals.

1. `preflight` without `probe` on a fresh home answers `reason: "not probed"` for every seat, spawns nothing, and is
   accepted from a non-owner caller.
2. `preflight` with `probe: true` from a seat child or a non-owner caller is refused with exit 3 and spawns nothing.
3. Owner `preflight --probe` on a codex stub whose probe prints `You've hit your usage limit ... try again at Oct 9`
   (exit 1) answers `usage_limit` with `until: "Oct 9"`; a stub printing `Insufficient balance` answers `no_credit`;
   a stub printing `{"name":"UnknownError","data":{"message":"Unexpected server error."}}` answers
   `model_unavailable`; a stub printing `database is locked` answers `busy`; a stub that sleeps past the cap answers
   `timeout`; a stub exiting 0 with `OK` answers `ok`. Every row carries `plan` and `availability`.
4. The probe argv is the seat's adapter argv with the prompt `Reply with exactly: OK` (asserted on the stub's record for
   codex, claude and opencode); the answer file and cwd are under `runs/preflight/<seat>/`; stdin is closed.
5. An opencode seat whose model is not a line of the stub's `models` output is `model_unavailable` with detail
   `not in opencode models` and the probe is not run; a model that is listed is probed.
6. A second `preflight` inside 600 s runs no stub process (cache); a `probe: true` call runs it again; after the seat's
   model is changed in config, the standing is `not probed` until the next probe.
7. The preflight detail never carries a credential: a stub printing `sk-` followed by 24 letters stores `[redacted]`
   in `preflights.detail` and in the reply.
8. `wake` on a council whose seat is `usage_limit` and whose only spare is `ok` but of a vendor already seated is refused
   with exit 4 and a message naming the seat and reason; the request row is `failed`; `briefs`, `snapshots`, `runs`,
   `sittings` and `seat_runs` gain no row; no seat process ran.
9. `wake` on a council whose seat is `model_unavailable` and whose spare is `ok` and of a new vendor sits with the spare
   in that slot, and the verdict's `independence` carries `fallback_used`.
10. `wake` on a council whose seats are all `ok` opens exactly as before (U7a `panel` council), and the probes for its
    seats ran once (cached standings serve the rounds).
11. `wake` with a synthesizer that is `not_logged_in` and no other non-recused synthesizer is refused with exit 4 before
    any row is written.
12. `ask` to a seat whose standing is `usage_limit` uses the route's first `ok` fallback and the `substituted` line names
    the fallback and `preflight: usage_limit`; with no fallback the ask fails with exit 4 and `preflight: usage_limit`
    in the error.
13. Two opencode seats of one blind round never run at the same time: the stub records start and end stamps and the
    intervals do not overlap; the sitting still reaches a verdict.
14. A `free` seat on a route with a hard dollar budget of 0 is admitted and charged 0 dollars; a `credit` seat on the
    same route is `refused: budget`; a seat with `plan: "free"` and a `price` is a config error naming the seat.
15. Plan defaults: a codex seat reports `plan: "subscription"`, an opencode seat with a `-free` model `free`, an
    opencode seat with another model `credit`, an ollama seat `local`; `plan: "gold"` is a config error.
16. After a sitting in which seat `a` answered, seat `b` was unparsable twice and seat `c` was `not_installed`,
    `seat_runs` holds exit 0 rows for `a`, exit 1 rows for `b` and no row for `c`; `scoreboard` gives `a` participation
    1/1 and `c` no cell; `preflights` holds `c`'s `not_installed` row.
17. `agencil seats presets` lists every preset name with harness, model, vendor and plan; `agencil seats add --preset
    glm-free` adds a seat that `SeatConfig` accepts with `vendor: "zhipu"`, `plan: "free"` and `hosted: true`;
    `--preset nope` exits 64; adding the same preset twice exits 4 with the name problem.
18. The panel seat items carry `standing` and `probed_ago`: `not probed` on a fresh home, `usage limit until Oct 9`
    after that probe, `model gone` after a `model_unavailable` probe.
19. `agencil preflight --json` exits 0 when every seat is `ok` and 4 otherwise; `--seats a,b` limits the rows to those
    seats; an unknown seat exits 64.

## 7. Not in this unit

A shared opencode server; a quality ranking of seats (the council's `spare` list is the owner's statement of equal or
better replacements); a scoreboard column for availability (it lives in the `preflight` reply); a models command for
codex or claude (neither CLI has one, the probe decides); fixing the PATH wrapper pick.
