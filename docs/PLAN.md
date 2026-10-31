# Agencil plan

## What it is

Agencil is a macOS menu bar app, a CLI and a local MCP server. Any local agent can ask any configured
seat (a named harness plus model, hosted or on a local or remote Ollama), or wake a council of several
seats that answer blind, argue, and reach a recorded verdict.

Every answer, verdict and later outcome (a fix commit, a revert, the owner's dismissal) is kept in a
local ledger. That shows which seat is right on which kind of change, proposes better councils, and
publishes an aggregate leaderboard to this repo's README.

The UI follows one enforced standard (`docs/DESIGN.md`), so it never drifts from its siblings MacMax, Bton
and RMJ. It adds a "the council thinks" visual layer that stays inside a measured CPU budget.

## Complete when

Agencil 0.1.0 is published on GitHub and installed with its public install line on the owner's Mac. Then:

- From a Claude Code session over MCP, `ask` to a non-Claude seat returns an answer.
- A chain "codex seat asks hermes seat asks claude seat" works, and the cycle back to the first seat is refused.
- `agencil wake` on a three-seat council returns a verdict with a minority report.
- The leaderboard card renders on the README from the `leaderboard` branch.
- The registry lists Agencil 0.1.0, and MacMax's More apps shows its card.

## Measured by

- `scripts/acceptance.sh` exits 0. In order it runs:
  1. `scripts/check.sh`: build, all tests including the design guards, the line limit, the ASCII lint.
  2. The screenshot render of every state in every look.
  3. `scripts/e2e.sh` against stub harnesses: ask, chain, cycle refusal, sitting, verdict, outcome ingest, leaderboard dry run.
  4. `scripts/perf.sh` against the CPU budget.
  5. The install line, with the installed version checked.
  6. The registry poll.
  7. A fetch of `leaderboard-dark.svg` from the `leaderboard` branch.
- `scripts/live-smoke.sh` on the owner's Mac runs named scenarios against real harnesses. A missing harness fails it; nothing is skipped silently. Required for 0.1.0: `claude`, `codex`, `opencode`, `hermes`, and one Ollama endpoint. Scenarios:
  1. `ask-codex-from-claude`.
  2. `chain-codex-hermes-claude`.
  3. `cycle-refused`.
  4. `sitting-3-seats`.
  5. `ollama-remote-ask`.
  6. `fallback-when-signed-out`.
  Its output is pasted into the release notes.

## Layout

Each unit is one branch, one PR, acceptance tests written by Codex first (from the "Acceptance" lines,
hashed in the PR), reviewed by Codex with the defect classes pasted in.

| Unit | Depends on | Touches |
|------|------------|---------|
| U0 Skeleton and ceremony | none | Package, Support, scripts, install.sh, .github, root docs |
| U1 Brand | U0 | Brand/, Support/ icons, render-icons.sh |
| U3 Core foundations | U0 | AgencilCore: home, config store, ledger, process runner |
| U2 House kit and guards | U0, U3 | Sources/Agencil/Kit, DemoStore, renderer, Tests/AgencilTests (U3 lands first; the look persists through its config store) |
| U4 Harness and model discovery | U3 | AgencilCore/Harness, Models, catalog.json |
| U5 Broker, CLI and MCP shells | U3 | AgencilCore/Broker, AgencilCLI, socket, MCP |
| U6 Seats, routes and ask | U4, U5 | Routing, threads, chains, adapters, MCP `ask` |
| U7 Councils | U6 | Sitting engine, answer contract, verdicts, triggers |
| U8 Panel | U2, U6, U7 | Panel views, bento, tabs, notifications |
| U9 Settings | U2, U6, U7 | Panes and sheets, Agent access installer |
| U10 Visual layer | U1, U8 | Kit/Synapse, menu bar frames, perf.sh |
| U11 Outcomes and scoring | U7 | Git and PR ingest, dispositions, metrics, golden set |
| U12 Learn loop (after 0.1.0) | U11, U16 | Proposals, cross-vendor review, apply and roll back |
| U13 Data and memory export | U11 | Retention, Bton memory export |
| U14 Leaderboard | U11 | Export, publisher, CI renderer, README card |
| U15 Council cutover | U7 | Parity with the owner's existing council script; the script becomes a wrapper |
| U16 Release 0.1.0 | all but U12 | README, screenshots, release, tap, registry |

0.1.0 ships outcome collection, scoring and manual council configuration. The automatic learn loop (U12)
and the Learn tab follow, once the scoring contract has real outcomes behind it (Codex review: an
automatic loop over an unproven score would tune toward noise).

## Units

### U0 Skeleton and ceremony
- Copy MacMax main's skeleton and rename it: `Package.swift` with targets `AgencilCore`, `Agencil`, `AgencilCLI`, `AgencilCoreTests` and `AgencilTests`; `bundle.sh` renames the CLI to `agencil` because of the case clash.
- `Support/`:
  - `Info.plist`: `LSUIElement` true, bundle id `ro.danieltamas.agencil`, the `AgencilSource` key stamped from git describe, minimum system 14.0.
  - `toolchain` pins the Xcode build.
  - `Registry/` comes from `registry-snapshot.sh`.
- `scripts/`: bundle, release, check, install-from-source, make-signing-identity, render-icons, tap, registry-snapshot, perf, acceptance, e2e, live-smoke.
- `install.sh` copies MacMax's flags: `--app`, `--uninstall [--purge]`, `AGENCIL_VERSION`, SHA256SUMS. It installs the CLI to `~/.local/bin`.
- `.release.json` is MacMax's, renamed. Its `verify` ends with the registry ping and poll from the registry's `docs/PRODUCER.md`.
- `.github/workflows/ci.yml` (macos-15, pinned Xcode, `check.sh`) and `release-verify.yml`, with actions pinned by SHA. Plus ISSUE_TEMPLATE and a pull request template.
- Root files: LICENSE (MIT), SECURITY.md (reporting, what Agencil is trusted with, threat model, data kept on the Mac), CONTRIBUTING.md, LOG.md (`## Unreleased`), and a README stub.
- Acceptance:
  - `swift build` produces `Agencil` and `AgencilCLI`. `scripts/bundle.sh` produces `Agencil.app` with the CLI at `Contents/Resources/agencil`. It is never in `Contents/MacOS`, where `agencil` and `Agencil` are the same file on a case-insensitive volume; MacMax `scripts/bundle.sh` avoids the same clash. `defaults read` shows the bundle id and `LSUIElement`. Signing, install.sh and the acceptance paths all use the Resources path.
  - `scripts/check.sh` fails on a 501-line Swift file and on a curly quote in docs/, and passes on the clean tree.
  - `scripts/release.sh 0.0.1 --verify` builds twice and the two ad hoc signed zips are byte-identical. As in MacMax, only the ad hoc archive is held to byte identity; a certificate-signed archive is not.
  - `install.sh --app <bundle>` installs to /Applications (or ~/Applications) and `agencil version` prints the version. `install.sh --uninstall` removes both.
  - CI passes on a pull request.

### U1 Brand
- `docs/BRAND.md`: three concepts, the owner picks, then the derived assets.
- Acceptance: as listed in `docs/BRAND.md`.

### U2 House kit and guards
- Codex writes the guard tests from `docs/DESIGN.md` "Enforcement" first. Each must be red on a seeded violation file and green on the kit.
- Copy the kit from the sources table in `docs/DESIGN.md`, rename the tokens, add `Tokens.swift` with the full scales, `.houseScheme()`, and the single look store.
- `DemoStore` uses synthetic data only. `--render-screenshots` uses MacMax's NSHostingView renderer.
- Acceptance:
  - Every guard in DESIGN "Enforcement" passes on `Sources/` and fails, naming `file:line`, on each of its adversarial fixtures:
    - `Task` moved 6 or more lines from the button, or into a helper function.
    - `Font.system(size:)` and `.system(size:weight:)` overloads.
    - `.white` and `Color(nsColor:)`.
    - `.frame(width: 37)`.
    - `.sheet(` with `ModalFrame` inside a wrapper.
    - A view that calls `withAnimation` around a loop.
  - Layout tests, rendered offscreen:
    - The panel is 404 pt in every tab and look.
    - Every row control measures 28 pt within 0.5.
    - Long names: with the 48-character repo, 60-character model id and 120-character reason, no `Text` has a rendered width below its ideal width unless the DESIGN text rules allow truncation for that field (commands, model ids: middle truncation), and nothing renders outside the panel bounds.
    - Empty states render in all looks.
    - Every pane renders at 760 x 540 without horizontal scroll.
  - Changing the look writes `config.json` `look`, and nothing else stores it (grep test: no `UserDefaults` key `look`).
  - Renders are deterministic: two runs give identical PNG bytes.

### U3 Core foundations
- `AgencilHome` (`~/.agencil`, `$AGENCIL_HOME`, 0700).
- `ConfigStore`, based on MacMax `ConfigStore`:
  - Holds an exclusive `flock` on `config.lock` for the read-modify-write.
  - Writes are atomic: a temp file in the same directory, `fsync`, then `rename`.
  - It refuses to write through a symlink or into a file not owned by the user.
  - It fails closed on a malformed file.
  - It carries a `revision` counter, so a write based on an older revision is refused and retried after a re-read, never merged blindly.
- `ProcessRunner`, from Bton/MacMax:
  - argv only, its own process group;
  - TERM then KILL on timeout, and a timeout is a failure even on exit 0;
  - the command is logged before it runs;
  - a PATH built per program;
  - stdin closed by default.
- Ledger `agencil.sqlite` through `libsqlite3`, parameterized statements only, with migrations numbered and tested. Tables:
  - `briefs`, `snapshots` (commit, diff hash, context manifest), `configs` (council and prompt versions with hash).
  - `runs` (thread or sitting), `seat_runs` (actual model identity, version, settings, timing, tokens, cost, exit), `requests` (caller, parent, chain).
  - `claims`, `evidence`, `assessments`, `verdicts` (scope, validity, independence flags, minority).
  - `outcomes` (source, adjudicator, certainty), `proposals`.
  - Records are appended or superseded, never overwritten.
- Acceptance:
  - Two processes each change a different key 100 times concurrently, and both sets of changes are present at the end.
  - A config with a syntax error makes every write fail with a visible problem, and the file is untouched.
  - A symlinked `config.json` is refused, not followed.
  - A crash between the temp write and the rename leaves the old file intact (fault injection).
  - A child that ignores TERM is killed with KILL after the grace period, and its grandchild is killed too (process group).
  - Migrations from an empty file to the latest schema pass, and re-running them is a no-op.
  - A claim edit creates a superseding row; the original stays readable.

### U4 Harness and model discovery
- Discover `catalog.json` kinds on the PATH built per program and in known install dirs. For each: path, version, signed-in state from the harness's own non-interactive status command (never by reading token files), and chain support (does it pass the environment to stdio MCP servers, tested with a probe server).
- The catalog of kinds that are not installed includes an install link that respects the owner's install policy (Homebrew on Apple silicon at `/opt/homebrew`).
- Models:
  - Hosted providers report "key present" by Keychain item name.
  - Ollama endpoints (local, and remote over the tailnet) are probed with `/api/tags` and `/api/ps`, which give health, models, loaded models and memory.
  - A model whose digest changed under the same name raises a "changed under its label" warning.
- Acceptance:
  - With stub harness binaries on a temp PATH, discovery lists each with its version, and a stub that hangs is reported `probe timed out` after 20 s without blocking the others.
  - Signed-in detection never opens a browser or a prompt (stubs that would block on stdin are killed and reported).
  - An Ollama stub returning a new digest for `qwen3:32b` raises the label-change warning once.
  - A remote endpoint is accepted only on `localhost`, a `100.64.0.0/10` tailnet address, or `https`. Plain `http` to any other host is refused (keys and code would travel in clear).

### U5 Broker, CLI and MCP shells
- The broker runs in the app (`agencil serve` headless) and listens on `~/.agencil/agencil.sock` (0600), one JSON request per line.
- Lifetime and recovery:
  - The broker holds an exclusive `flock` on `broker.lock` for its whole life. Only the lock holder may remove a stale socket and create a new one, so two launches race safely.
- Launch handshake:
  - The broker writes a launch intent with a random nonce and the reservation before spawning.
  - It starts the seat through the CLI's launcher mode (`agencil run-seat <nonce>`). The launcher puts itself in a new process group, reports its pid, pgid and start time to the broker over the socket, and waits for `go`.
  - Only after the broker records them does it reply `go`. The launcher then `exec`s the harness in the same process, so no model call can start before its identity is in the ledger.
- On startup the broker reconciles every open intent:
  - An intent with no recorded pid (a crash between spawn and registration) is resolved by finding any process whose launcher argv carries that nonce and killing its group.
  - A recorded process alive with the matching start time is adopted or killed per policy.
  - A run is marked `interrupted` only when no process remains in its process group, descendants included. Only then is its reservation released.
  - Each request reads the peer pid of its socket connection (`LOCAL_PEERPID`) and records it.
- The CLI and `agencil mcp` are thin clients. MCP covers JSON-RPC 2.0, both protocol versions, the 1 MB cap and the envelope (`docs/AGENT-API.md`).
- Agent access is off by default: tools answer `refused`.
- `install-mcp <harness>` writes, verifies and uninstalls per `docs/AGENT-API.md`.
- Acceptance:
  - With no broker, every client verb exits 3 with the documented message.
  - The socket is created 0600, and a second broker refuses to start while the first is alive.
  - The MCP handshake succeeds on both protocol versions.
  - `install-mcp codex --dry-run` prints a diff and changes nothing.
  - Install writes atomically under a lock and records the entry's hash in `~/.agencil/installed.json`.
  - An existing `agencil` entry that Agencil did not write is refused, not replaced, and reported.
  - Uninstall removes the entry only if its hash is unchanged since install. On an otherwise untouched file it leaves the file byte-identical to before.
  - A config file that does not parse, or is a symlink to a file the user does not own, is untouched and reported.
  - Killing the broker with SIGKILL while a stub seat runs, then restarting: the seat is found by its intent, killed by process group (or adopted), the run is marked `interrupted`, and its reservation is released only after every process in the group is gone. Tested with a stub whose child outlives the leader.
  - Killing the broker between spawn and the launcher's registration: after restart the launcher is found by its nonce and killed, and no harness ever started (the stub records whether it was exec'd).
  - Two brokers launched within 10 ms of each other: exactly one serves; the other exits with a message.
  - Exit codes match the table in `docs/AGENT-API.md` for every verb.

### U6 Seats, routes and ask
- Seat, route and alias config.
- Resolution steps 1 to 5 in `docs/AGENT-API.md`, each with its failure reason.
- Harness adapters with hardened argv. Each adapter has its own test of the argv it builds after placeholder expansion.
- Threads with follow-ups: resume the harness session where the adapter supports it, else resend the transcript.
- Chains per `docs/AGENT-API.md` "Chains, hops and loops": a per-run capability, the process-tree check, hop limit, cycle and replay refusal.
- Budgets and capacity per `docs/AGENT-API.md` "Budgets and capacity": durable reservations, reconciliation, chain charging, parked ancestors.
- Acceptance:
  - A call with no route is refused and runs nothing.
  - `ask` to a seat whose harness is not signed in uses the route's first usable fallback and records the substitution. With no fallback it fails with the reason.
  - The chain A asks B asks C succeeds at hop limit 2; C asking anyone is refused at hop 3. C asking A is refused as a cycle at any hop limit.
  - Chain tests, each with stub seats that call `agencil ask` through the CLI and through MCP:
    - Environment stripped: the process-tree check still attributes the call to its parent and the hop limit holds.
    - Capability replaced with another live run's: refused (`capability does not match caller`).
    - Capability replayed after its run ended: refused.
    - CLI recursion from a seat (no MCP): bounded exactly like MCP.
    - A process detached from the seat's tree with no capability: treated as a new root and counted against the root rate limit. This is the documented same-user limit.
  - With seats at once = 1, the chain A asks B asks C completes, because parked ancestors do not hold the slot.
  - A chain that would exceed the process cap is refused at once, never left waiting.
  - Two concurrent asks over a budget that fits one: exactly one reservation succeeds and the other is refused `budget`.
  - After 1,000 randomized asks with stubs reporting costs (some reporting none), retries and fallbacks, the sum of charges never exceeds any hard cap. Runs with no usage report stay charged at their full reservation.
  - An unbounded seat is refused on a route with a hard dollar cap and allowed on an estimated one.
  - A single-call stub's request carries `max_tokens`, and its reservation equals prompt bytes x input price + `max_tokens` x output price.
  - A run whose worst case exceeds the remaining hard budget is refused before the spawn.
  - A failed peer-pid read or ancestry walk (fault-injected) refuses the call, never treating it as a root.
  - A follow-up on a thread reaches the same seat and its stub receives the earlier exchange.
  - Briefs are written inside the run's worktree under `.agencil/` when the harness restricts external directories.
  - A hosted seat on a local-only council or route is refused even when it is only a fallback. Residency is checked after resolution, not before.
  - The outbound packet to a hosted seat contains no file matched by the redaction rules (`.env*`, key and token patterns, `.agencilignore`); asserted on the files present in the seat's copy and on the prompt bytes.
  - Inside a confined stub seat, each of these reads fails:
    - `~/.ssh/id_ed25519`;
    - `../` outside the copy;
    - a symlink in the repo pointing at `$HOME`;
    - `.git/config`, which does not exist in the copy;
    - the real repo's path.
  - An adapter that cannot apply its read-only, no-network policy for a hosted seat refuses the run; it does not degrade.

### U7 Councils
- Frozen packet per sitting:
  - Every seat of a sitting (and every ask that names a repo) runs in a detached worktree at the snapshot commit, `~/.agencil/worktrees/<run>`, never in the live checkout.
  - Uncommitted changes the caller wants reviewed are captured as a patch, applied in the worktree and hashed into the snapshot id. Dirty files that are not captured are absent, never read live.
  - Hosted seats get a sanitized copy of that worktree (redaction rules removed).
  - Every answer, round and verdict row carries the snapshot id.
  - The worktree is removed when the run ends.
- Rounds: blind first, answers stored before anyone sees the others, then rebuttal with the others' claims as labelled evidence, then an optional challenge round for disputed blockers.
- The answer contract with parse, one retry, then `failed: unparsable`.
- Silent-seat detection: no output for a configured share of the cap means swap or abstain.
- Recusal is absolute:
  - A seat of the author's vendor is removed from the sitting.
  - The synthesizer is never the author's vendor; when no other synthesizer is available the verdict is `INCOMPLETE`.
  - The author's vendor comes from the brief (`author_vendor`, also `agencil wake --author-vendor`). When it is missing, the caller's harness vendor is used if the caller is a known harness.
  - Otherwise the author is `unknown`. An unknown or unrecognized author sets the independence flag `author_unknown`: recusal cannot be proven, so a high-risk council returns `INCOMPLETE`, and other councils run with the flag shown on the verdict.
- Votes: each seat's answer carries `vote` (`approve`, `block`, `abstain`) next to its claims (`docs/AGENT-API.md`).
  - A valid vote is answered, parsed and not abstained.
  - Default quorum: a majority of the configured seats, and at least 2 distinct vendors among the valid votes for a council of 2 or more.
- Verdict truth table, evaluated in this order (first match wins):

  | Condition | Verdict |
  |-----------|---------|
  | Synthesizer failed or unparsable | `INCOMPLETE` |
  | Valid votes below quorum | `INCOMPLETE` |
  | Council is high-risk and any independence flag is set (fallback used, a vendor missing, quorum met only by one vendor, `author_unknown`) | `INCOMPLETE` |
  | Rule `any blocker`: an unrefuted `p0` or `p1` claim with at least one backer | `BLOCK` |
  | Rule `any blocker`: no such claim | `PASS` |
  | Rule `unanimous`: every valid vote is `approve` | `PASS`, else `BLOCK` |
  | Rule `majority`: more than half of the valid votes are `approve` | `PASS`, else `BLOCK` |

  A claim is refuted when, in the challenge round, more distinct-vendor seats dispute it than back it with evidence. A tie is not refuted.
- The minority report is kept: every claim a non-majority backed, with its seat and vendor.
- Triggers ("Wake on": path globs like the owner's trust paths, PR label via `gh`, schedule) with debounce and quiet hours. A trigger never fires on a timestamp the sitting itself moves (Bton invariant 11).
- Acceptance:
  - Seat B's blind answer is written before seat A's rebuttal prompt is built, and B's blind prompt contains nothing from A (asserted on stub inputs).
  - Unparsable output twice gives `failed: unparsable`, and the seat is excluded from the vote count.
  - A seat silent past its threshold is swapped when the council has a spare seat, else marked abstained, and the verdict is `INCOMPLETE` when quorum is lost.
  - Every row of the verdict truth table has a test with stub seats, plus a test for the order. For example: synthesizer failed and every vote `approve` gives `INCOMPLETE`.
  - With the author's vendor as the only configured synthesizer, the verdict is `INCOMPLETE`.
  - A brief with no `author_vendor` from a CLI caller, and a brief with `author_vendor: "acme-ai"` (unrecognized), both set `author_unknown`: `INCOMPLETE` on a high-risk council, flagged on others.
  - `any blocker` with no qualifying claim returns `PASS` and with one returns `BLOCK`.
  - A seat of the author's vendor is never spawned (asserted on spawned argv).
  - Two seats reading the same worktree while the live checkout changes: both answers carry the same snapshot id, and the changed file's new content is absent from both stub inputs.
  - A claim supported by one seat and disputed by two appears in the verdict's minority report with its seat.
  - A trigger whose own sitting labels the PR does not fire again on the next sync (a test where the only change is Agencil's label).
  - Verdict JSON matches `sitting_verdict` in `docs/AGENT-API.md`.

### U8 Panel
- Header, bento, tabs (Threads, Sittings, Findings, Seats; Learn comes with U12) and footer, exactly as in `docs/DESIGN.md`.
- Notifications, never on the first tick: a verdict, a BLOCK, a seat died, the budget at 80%, a thread failed. Each can be turned off in General.
- Acceptance:
  - Every DESIGN layout test passes for the panel.
  - Bento counts only items a human must act on (fixture: 3 open findings, 2 confirmed, 1 proposal gives 4).
  - With no config, the bento shows the first step.
  - Every list shows its waiting state before the first read.
  - Stop on a live sitting shows "Stopping..." at once and kills the seat process groups.
  - A second press while stopping does nothing.

### U9 Settings
- Panes and sheets exactly as in `docs/DESIGN.md`, saved through the config store.
- Agent access cards per detected harness, with install and uninstall (U5) and the instruction file per harness.
- Acceptance:
  - Every pane and sheet renders at 760 x 540.
  - A sheet with an invalid field does not close and shows `ProblemText` on that field.
  - Creating a seat, a council and a route from sheets produces config the broker accepts without a restart.
  - Changing a scalar writes it once.
  - "Install for codex" writes the entry and shows it read back.
  - A harness config that does not parse shows the problem and is untouched.

### U10 Visual layer
- `Kit/Synapse/` scenes, menu bar frames and backdrop mesh, per `docs/DESIGN.md` "Visual layer".
- Acceptance:
  - `scripts/perf.sh` meets every budget in the DESIGN table, using the DESIGN measurement method.
  - With the panel hidden, no `CAAnimation` is running in the panel's layer tree (inspected in a test host); the menu bar animation runs only under its own rules.
  - Reduce Motion gives cross-fades only.
  - `stillImage` renders the final frame.
  - A sitting with 5 seats and 40 claims animates every claim's spark exactly once.

### U11 Outcomes and scoring
- Outcome evidence:
  - From git: commit bodies naming `AG-` claim ids, and reverts of such commits.
  - From PRs via `gh`: a dismissal comment.
  - Evidence is not a label. A fix commit is `evidence: fix-commit`, pending.
- Adjudication turns evidence into a label. A commit surviving or being reverted is never a label on its own.
  - The owner's Confirm or Dismiss is final.
  - Otherwise an **adjudication seat** labels it: a seat of a vendor that did not raise the claim and did not synthesize the verdict. It reads the claim, its evidence and the fixing commit's diff (or the revert), and answers `confirmed`, `refuted` or `cannot tell`, with a reason.
  - The label is recorded with its adjudicator and certainty. `cannot tell` stays pending, and the owner can override any label.
  - After the unresolved window (30 days) a finding with no label is `unresolved`, never `wrong`.
- Duplicates: claims of one sitting that the synthesizer links as the same finding, or that share file and line within 3 lines and kind, form one finding. Each seat that raised it is credited once.
- Metrics per seat and change kind:
  - **Confirmed share** (precision): confirmed / (confirmed + refuted) over adjudicated findings. Unresolved findings are excluded. A zero denominator shows `n=0`, never 0%.
  - **Coverage**: of the confirmed findings in sittings where the seat gave a valid answer, the share it raised.
    - Sittings where it abstained or failed are excluded and counted in a separate **participation** rate.
    - A zero denominator shows `n=0`.
    - This is a relative measure, labelled as such, and is not recall.
  - **Recall** is computed only on the golden set, where every defect is known: found / known, summed over every golden brief the seat was given.
    - An abstention or failure on a golden brief stays in the denominator and counts as found 0.
    - Clean golden briefs (zero known defects) add nothing to recall. They measure the seat's **false alarm rate**: the share of clean briefs where it raised any p0 or p1.
    - When the known total is 0 it shows `n=0`, never 0%.
  - Also: cost per confirmed finding, median time, overlap between seats, and Wilson 95% intervals on every share.
- Golden set: labeled briefs with every known defect listed. It is a probation gate for new seats and prompts and is never used for tuning. A seat passes probation with golden recall of at least the council type's floor (default 0.5) and golden confirmed share of at least its floor (default 0.6), over at least 10 golden briefs.
- Acceptance:
  - A commit body `Fixes AG-41-3` records pending evidence and labels nothing.
  - An adjudication seat's `confirmed` labels it, recorded with its adjudicator. The seat that raised the claim, or the synthesizer, is never chosen as adjudicator (asserted on the spawned seat).
  - The owner's Dismiss overrides any label.
  - A finding confirmed by a revert alone stays pending.
  - A claim with no event in 30 days is `unresolved` and is excluded from confirmed share, coverage and the leaderboard.
  - Two seats raising the same `file:line` finding produce one finding credited to both, and confirming it counts once per seat, not twice.
  - The leaderboard and the Seats tab never show a field named recall computed outside the golden set (a test on the export and view model).
  - Wilson intervals match a reference table to 3 decimals.
  - A seat on probation that scores under the type's floor on the golden set cannot be added as a voting seat (sheet shows why).
  - Scoreboard query on 10k claims and 100k assessments returns in under 50 ms.

### U12 Learn loop
- A weekly job writes proposals (drop, add or swap a seat, a prompt change), each with the outcome evidence and n.
- No proposal is made under 20 outcomes per seat and change-kind cell. Prompt changes vary one variable per council type at a time.
- A different vendor's seat reviews each proposal. The owner approves; approval writes a new config version, and rollback restores the previous one.
- Acceptance:
  - With fixture outcomes under the minimum, no proposal is written.
  - An approved proposal creates a new council config version and the next sitting uses it.
  - Rollback restores the exact previous version (hash equal).
  - The reviewing seat is never the vendor whose seat the proposal touches.
  - Nothing is applied without an owner approval event.

### U13 Data and memory export
- Retention for raw seat outputs (default 90 days) and claims (forever); a ledger size readout.
- An optional export of each sitting as Markdown into a Bton memory folder per repo, with path and on/off per repo.
- Acceptance:
  - Retention deletes raw outputs past the window and keeps claims, verdicts and outcomes.
  - The export writes one file per sitting, idempotent on re-run, only for repos turned on.

### U14 Leaderboard
- Everything in `docs/LEADERBOARD.md`.
- Acceptance:
  - `agencil leaderboard preview` prints only allowlisted fields. A fixture ledger containing a repo name, a path and claim text yields a `data.json` with none of them (grep test on the output).
  - A seat whose model is not in the public model list and has no owner-approved public name is absent from the export (a local model named `client-project` never appears).
  - The PUT request body carries `branch: leaderboard`, base64 `content`, `message` and the expected `sha` (asserted on the recorded request). A run against a test repo leaves the default branch untouched.
  - The render workflow, run on a fixture `data.json`, produces the SVGs and `LEADERBOARD.md` on `leaderboard` and changes nothing on `main`. Two publishes in a row serialize through the workflow's concurrency group.
  - A cell with n 19 at `min_n` 20 is absent.
  - `validate.py` rejects an unknown key, a bad model string and a low-n cell.
  - `render.py` output is deterministic for a fixed `data.json`.
  - Publishing with a stale blob sha fails, re-reads and retries once.
  - Publishing is off until the first manual press.

### U15 Council cutover
- Port the semantics of the owner's existing council script into a built-in council type (seats, caps, probe-only mode, optional Ollama seats).
- The script then becomes a thin wrapper over `agencil wake` with the same arguments, and the owner's `ship` workflow security pass calls Agencil. That way there is one council engine, not two.
- Acceptance:
  - Before any code: capture fixtures from the old script on stub seats, covering its argv, the files it writes, its exit codes, its probe-only output and its seat-list environment override. They are committed under `Tests/Fixtures/council-script/`.
  - The wrapper reproduces every fixture: same exit code, same output files and their structure, the same seats invoked with the same caps.
  - The old script's probe-only flag maps to `agencil harnesses --probe`.

### U16 Release 0.1.0
- README product page, MacMax's shape:
  - icon, tagline, the install line, the leaderboard card;
  - bold-lead feature paragraphs, each with a synthetic screenshot;
  - For agents, Build from source, Privacy and security, License.
- The release through `.release.json`: build, assets, verify. Verify covers the installed version, `tap.sh`, the registry ping and the poll.
- Homebrew cask `danieltamas/homebrew-tap` `Casks/agencil.rb` via `tap.sh`.
- Registry, in danieltamas/registry, in one commit after the GitHub release exists (a repo with no release reads as `latest: null` and consumers would show an empty card):
  - `apps.json` entry: id `agencil`, name `Agencil`, kind `menu-bar`, platform `macOS`, pitch at most 80 characters and detail at most 200 (user-facing, no internals), repo, icon `icons/agencil.png`, `iconShape: macos`, install `brew install --cask danieltamas/tap/agencil`, `mac.bundleId` `ro.danieltamas.agencil`, `sourceKey` `AgencilSource`, hue from the final icon.
  - The registry README's app list.
  - The project table in `prompts/announce-releases.md`.
  - `python3 scripts/validate.py` exits 0.
- Acceptance:
  - The install line on a clean user account installs 0.1.0.
  - `brew install --cask danieltamas/tap/agencil` installs the same checksum.
  - The registry raw `apps.json` shows `agencil` `latest.version` 0.1.0 within 3 minutes of the ping.
  - MacMax's More apps pane shows the Agencil card after its hourly refresh.

## Quality criteria

- **Code:**
  - Swift 6 strict concurrency; `@MainActor @Observable` store; background loops started in the App init, never in views.
  - One process helper; one config store; files at most 500 lines; one concern per file in Core.
  - Names match the siblings (`AgencilHome`, `ConfigStore`, `ProcessRunner`, `AsyncPress`).
  - No dead code.
- **Tests:**
  - Swift Testing, `<Topic>AcceptanceTests` written by Codex from this file and hashed in the PR, plus `<Topic>RegressionTests` for each fixed bug.
  - Stub harnesses under `Tests/Fixtures/harnesses/` for CI; `live-smoke.sh` for real harnesses on the owner's Mac.
  - No tautological unit tests: assert on the argv, the ledger rows, the socket replies and the rendered pixels.
- **Speed:**
  - Overhead of an ask (route, resolve, spawn), excluding the model: under 300 ms.
  - Socket round trip: under 10 ms.
  - Panel first frame with 10k claims: under 100 ms.
  - Scoreboard query: under 50 ms.
  - CPU budgets: as in the DESIGN table.
  - All measured in `perf.sh`.
- **UI:**
  - `docs/DESIGN.md`, enforced by its guard and layout tests.
  - Every press shows its state at once.
  - Labels never wrap.
  - "UI not exercised live" is said when it was not.
- **Security** (trust boundaries and their checks):
  1. Repo content and seat answers into prompts: labelled evidence only, never instructions; prompts carry identities (SHAs, ids).
  2. Callers: route check, hop limit, cycle and unknown-parent refusal, budgets. MCP and routes are off or refuse by default. Same-user processes are not a boundary (stated in SECURITY.md).
  3. Egress to hosted models. The outbound boundary is everything a hosted seat can read: the prompt, the earlier rounds' claims, the thread transcript, and its worktree.
     - Hosted seats get a sanitized copy, built with `git archive` of the snapshot plus the captured patch. It has no `.git`, no history and no back-pointer to the real repo. Symlinks that resolve outside the copy are removed, and the redaction rules are applied (`.env*`, key and token patterns, `.agencilignore`).
     - The prompt and claims pass the same scrubber.
     - The adapter applies a read-only, no-network tool policy (or refuses).
     - Filesystem confinement: the seat process runs under a macOS sandbox profile, applied by the launcher before `exec`. Network goes only to the provider. File reads are allowed only in:
       - the sanitized copy;
       - the harness's install directory (binaries, read-only);
       - a fresh per-run config home (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME` and the like, pointed at a temporary directory). It holds only the adapter's config and the harness's own credential, so no other session, history or memory file is readable.
     - Residual by design: the harness can read its own credential, which it needs to call its provider. How the credential reaches the fresh home differs per harness (decision D12).
     - A harness that cannot run confined is refused for hosted runs on code (decision D11).
     - Residency is checked after fallback resolution.
     - Logs record argv with prompt bodies replaced by their hash.
     - All of this fails closed.
  4. Keys: Keychain by item name, never logged, never shown after save.
  5. Seat processes: hardened argv per vendor, read-only sandbox where the harness has one, stdin closed, process-group kill.
  6. Remote Ollama: tailnet, localhost or https only.
  7. Harness config writes: diff, write, read-back, exact-entry uninstall; an unparsable file is untouched.
  8. Leaderboard: aggregate allowlist, min n, opt-in, compare-and-swap writes, validation in CI. A failure publishes nothing.
  9. Update and install: checksums, pinned release, Update only from /Applications.
  - What is left by design:
    - A same-user process can call the socket, and one that detaches from a seat's process tree and drops its capability looks like a new root. It is still bounded by root rate limits and budgets, but not by the chain.
    - Seats run the harnesses' own code with the owner's credentials.

## Open decisions

| Id | Question | Options | Recommendation |
|----|----------|---------|----------------|
| D1 | Shared kit | Vendored `Kit/` folder; a shared Swift package used by all four apps | Vendored now, with no app imports, so extraction is mechanical; extract when a second app adopts it |
| D2 | Ledger store | SQLite only; Markdown only; both | SQLite is the truth; Markdown export to Bton memory (U13) for agent search |
| D3 | Broker | In the app plus `agencil serve`; a LaunchAgent daemon | In the app plus `serve`; a daemon only if headless use becomes common |
| D4 | Logo concept | Ring and core; converging arcs; council table | Owner chose "generate one": concept 1, ring and core, drawn in `Brand/icon-app.svg` and `Brand/icon-menubar.svg` |
| D5 | Caller identity | Caller id from the MCP install args; axon identity when axon runs | Install args now; read the axon identity when present, as a refinement, not a requirement |
| D6 | Minimum macOS | 14; 15 | 14, like Bton and RMJ |
| D7 | Bundle id | `ro.danieltamas.agencil` | As listed |
| D8 | The existing council script | Keep both; wrapper over Agencil; retire | Wrapper (U15), so there is one engine |
| D9 | Publishing model comparisons | Publish all; exclude providers whose terms forbid it | Check each provider's terms before the first publish, then exclude by provider and model if needed |
| D10 | MCP that acts | Read-only like MacMax/RMJ; acting tools gated by routes | Acting tools gated by routes, off by default; it is the product |
| D11 | Confining hosted seats | `sandbox-exec` profile (deprecated by Apple but working); an App Sandbox helper; refuse unconfinable harnesses | A `sandbox-exec` profile per adapter, tested on each macOS release; refuse a harness that breaks under it |
| D12 | Credential in the per-run config home | Copy the harness's credential file into it; let the sandbox profile read only that one Keychain item (Claude Code keeps its sign-in in the Keychain, not a file); an API key from Agencil's own Keychain item passed by env | Per harness, settled by the adapter probe in U6; a harness that cannot authenticate from a fresh home is refused for hosted runs on code |
