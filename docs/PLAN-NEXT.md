# Next plan: availability, harnesses, effort, then the deferred list

Written 2026-11-01. It consolidates U25 (seat preflight, done on branch `seats-preflight`, gate red), the harness
list review, the effort measurement idea and the UI pass that is still open. Order matters: each step starts from the
observable end state of the one before it.

## 0. Where things stand

| Branch | State | Blocker |
|--------|-------|---------|
| `ui-pass` | UI pass 1-4, More apps and About ported from MacMax, look saved, tab island as the siblings. Installed. `scripts/check.sh` green at 75fed46 | The owner has not yet approved the UI; no cross-vendor review of the UI diff yet |
| `seats-preflight` (from `ui-pass`) | U25 committed as 9629336, 23 U25 tests green | `scripts/check.sh` exit 1: 22 issues in older hashed tests that contradict the new wake gate (decision D1) |

## 1. Decision D1 - the wake gate versus the older acceptance tests (owner)

The owner asked for "no failed runs": a council whose seats cannot answer must be refused before any work. U25 does
that, and so older tests that expect a bad seat to fail inside a running sitting (exit 0 or 2) now see exit 4.

- Option A (recommended): U25 supersedes those assertions. Another vendor (Codex) rewrites the affected tests from the
  U25 spec and the manifests are re-hashed. Two source changes go with it: budget admission moves ahead of the gate,
  and the gate's probes run through `Capacity` so `seats_at_once` still bounds concurrent processes.
- Option B: the wake probe is opt-in per council. Keeps old tests, but leaves the default council able to fail
  mid-run, which is what the owner asked to remove.

Affected tests (from the U25 report): U7aIndependence (3), U7aConfig (1), U7aVerdict (3), U15b observation counts
(4), U7a budget-before-spawn and seats-at-once (2), U7aLifecycle stop (1).

## 2. Step A - land U25

End state: `rmj run -- scripts/check.sh` exits 0 on `seats-preflight`; the branch is fast-forward merged into the UI
branch line, then main, only after the owner has seen the UI.

1. Apply D1 (Option A). Tests rewritten by Codex, never by the implementer; manifests re-hashed.
2. Cross-vendor review of the U25 diff: Codex `gpt-6-astra` with high reasoning, read-only, with the MacMax
   `docs/LESSONS.md` section 9 defect classes and a security pass (the gate decides what runs, so it is a
   fail-closed path). Fix every P0-P2 and review again.
3. Live proof, not unit proof: on this Mac run `agencil preflight --probe` against the seats the owner enables
   (claude, codex, the free opencode models that exist now) and record the output in `docs/reviews/`.
4. Measure: the same preflight must refuse a rotated-out opencode model in under 5 seconds and a dead panel without
   writing a sitting. Acceptance: zero sittings and zero seat runs are written for a refused wake.

Open limits carried from U25: no shared opencode server (one process at a time per broker); an ask to a seat with no
fresh standing runs without a probe; availability shows in the `preflight` reply but not as a scoreboard column;
historical ledgers keep NULL exit codes so participation stays 0 until new sittings run.

## 3. Step B - the harness catalog

End state: the New seat picker lists the most used harnesses, each with a verified headless command, a sign-in check
where one exists, an install hint and a plan type.

Present: claude, codex, opencode, hermes, gemini, aider, goose, ollama.

Candidates, in order of use: Mistral Vibe (`mistral-vibe`, headless `vibe --prompt`, key in `MISTRAL_API_KEY`; note
that a different `vibe` binary exists on this Mac, so detection must check what it is, not only its name), Cursor
(`cursor-agent`), GitHub Copilot CLI (`copilot -p`), Qwen Code, Kimi CLI, Droid, Amp, Crush, Cline.

Method per harness: read its own `--help` and docs, record the headless flag, the status command (or "unknown"), the
version command and the plan type; add it to `catalog.json`, regenerate `CatalogData.swift` with
`scripts/sync-catalog.sh`; add the preflight classifier lines its error texts need. A harness whose headless flag was
not verified against its own `--help` is not added.

Acceptance: `agencil harnesses --probe` lists each installed harness with version and sign-in; the picker shows all
added ones; the catalog and generated file agree (`check.sh` enforces it). The model named "le chonk" is not added
until the owner gives its id: a seat is a harness plus a model, so the harness entry covers any Mistral model.

## 4. Step C - effort per seat run

End state: every seat run records how much work it took, and the panel and leaderboard can show efficiency without
changing the accuracy score.

1. Ledger migration: `seat_runs` gains `turns`, `tool_calls`, `wall_seconds` (null when a harness does not report).
2. Parsers per harness from its own output: Claude JSON turn count and tool uses, Codex step log, OpenCode message
   count. A parser failure records null, never a guess.
3. Scoring: efficiency is reported beside accuracy (confirmed findings per turn, per dollar, per minute) and is never
   part of the accuracy rank. An availability failure is never a wrong answer: it counts in an availability rate.
4. Learn loop: new proposal kinds the owner approves one by one: lower a seat's step cap, replace a seat that spends
   many turns and adds no finding the others missed, prefer a cheaper seat for a change kind where it matches.
5. Early warning: a seat far above its own median turns is flagged on the panel before it reaches the time cap.

Acceptance: a seeded ledger of 40 seat runs yields stable efficiency numbers; a null-effort run is shown as unknown;
the accuracy ranking is byte-identical with and without effort data. Tests come from another vendor from this text.

## 5. Step D - finish the UI pass, then show it

End state: the owner has used the panel and Settings on the installed build and approved them, `ui-pass` is merged.

- Remaining: cross-vendor review of the UI diff; verify live that the Settings button opens in front and that
  Restart, Quit and the tab island behave; check text wrapping at 404 pt on real data; cursor audit of the remaining
  clickable items.
- Not in 0.1.0 by DESIGN.md: nothing further is queued for the Learn tab beyond what shipped.

## 6. Step E - the deferred engineering list (after the owner has seen the UI)

Leaked-app cleanup in `Tests/Acceptance/U0/test_install_slow.sh`; `recoverOpenLaunches` `try?`; sandbox profiles;
McpInstaller issues; Reduce Motion live toggle; WindowServer CPU in `perf.sh`; will-fix label; leaderboard golden map;
pending adjudication ownership. Then the owner's own steps: cut over `~/agent-os/council.sh` to the Agencil wake
(open item `u15-engine`) and the U16 release (tag, GitHub release, tap cask, registry).

## 7. Quality criteria for every step

Another vendor writes the acceptance tests from the written end state and the implementer never edits them; every
diff gets one cross-vendor review; availability and safety decisions fail closed on every branch (error, timeout,
5xx, stale, ambiguous); nothing is claimed done without the command that proves it and its output; files stay under
500 lines; plain ASCII; no client, host or personal names in a public repo.
