# U7 contract: councils and sittings

`docs/PLAN.md` U7 owns the rules (rounds, recusal, quorum, truth table). This file fixes everything the plan leaves
open so tests and code agree. It is observable through `wake`, `result`, `status`, `stop`, the files and prompts a
stub seat sees, and the ledger rows named below. U7 is built in two pieces: **U7a** (everything here except
"Triggers") and **U7b** (triggers).

## Config

`councils`: one more key of `config.json`, JSON text like `seats`; invalid -> every op fails with
`failed: config councils is invalid: <problem>` and nothing runs.

```
{"name": str, "seats": [seat-name], "spare": [seat-name]?, "synthesizer": seat-name | [seat-name]?,
 "rule": "any_blocker|unanimous|majority" (default majority), "high_risk": bool (default false),
 "quorum": int?, "rounds": {"rebuttal": bool (default true), "challenge": bool (default false)}?,
 "residency": "any|local" (default any), "silent_after": number 0.05...0.95 (default 0.5),
 "deadline_seconds": int 10...7200 (default 1800)}
```

- `name`: same pattern as a seat; unique among councils; not the name of a seat or alias.
- `seats`: 1 or more distinct existing seat names. `spare`: distinct existing seats, none in `seats`.
  `synthesizer`: existing seats, not in `seats`; the first usable one that is not recused runs the synthesis.
- `quorum`: whole number from 1 to `len(seats)`; absent means the default quorum (see Votes).
- Seats gain an optional `vendor` (`[a-z0-9][a-z0-9-]{0,39}`; invalid -> `failed: config seats is invalid: ...`).
  Default vendor: `claude` -> `anthropic`, `codex` -> `openai`, `gemini` -> `google`, every other harness -> the
  harness name. A route's target may be a council name; a caller reaches a council only through such a route, and
  route `fallbacks` do not apply to councils.

## Wake

`wake` (broker op; CLI `agencil wake <council> --brief <file> [--repo <path>] [--diff <range>] [--author-vendor <v>]
[--wait <s>]`; MCP `wake_council`): fields `council`, `change_kind`, `question`, `diff?`, `repo?`, `author_vendor?`,
`uncommitted?` (bool), `wait_seconds?` (default 60). The brief file is `key: value` lines; `--author-vendor` and
`--repo` override the file; the file may carry `author_vendor:` and `uncommitted: true`. Missing `change_kind` or
`question`, or a `code` brief with no `diff`, is a usage error (exit 64, as before U7).

Order of refusals, each writing a refused `requests` row and no `runs` row: no route from the caller to the council
(`refused: no route from <caller> to <council>`, exit 3); unknown council (`failed: no council named <name>`, exit 4);
`repo` that is not a git work tree top (`failed: repo <path> is not a git repository`, exit 4).

Reply: `{"sitting": "sit_<hex>", "state": "pending|done|failed", "verdict"?: ..., ...}` waiting up to
`wait_seconds`. CLI exit: `PASS` 0, `BLOCK` 1, `INCOMPLETE` 2, pending 2, failed 4.
`result <sitting>` waits the same way and returns the full verdict JSON; `status <sitting>` returns
`{"sitting", "council", "state", "round", "seats": [{"seat", "vendor", "state", "round", "thread"?}]}`;
`stop <sitting>` stops every running seat thread, ends the sitting `failed` with reason `stopped`.

## Author and recusal

`author_vendor` (lowercased) is **known** when it is a built-in vendor (`anthropic, openai, google, meta, mistral,
alibaba, deepseek, moonshot, zhipu, xai`) or the vendor of any configured seat. Missing: the vendor of the caller's
harness kind when the caller is a known harness (a seat's child, or an agent whose harness kind is attributed);
otherwise `unknown`. Present but not known: treated as `unknown`. When the author is `unknown` the independence flag
`author_unknown` is set; no seat is recused.

A seat whose vendor equals the known author vendor is removed from the sitting before anything is spawned: it is
neither convened nor used as a spare nor as the synthesizer. If no synthesizer remains (none configured is fine and
means no synthesis step; configured but all recused or unusable is not) the verdict is `INCOMPLETE`.

## Snapshot (the frozen packet)

With a `repo`, the sitting resolves `HEAD` to a commit once, at wake. With `uncommitted: true` the tracked
working-tree changes (`git diff HEAD`) are captured as a patch, hashed, and applied to every seat's copy. Every seat
of every round works in its own copy (U6d: `runs/<thread>-<seq>/copy`, redacted for hosted seats) exported from that
commit and patched identically, so a file changed in the live checkout after wake is absent from every seat's input.
Snapshot id: `sn_` + the first 16 hex of `sha256(commit "\n" patch-sha256 "\n" sha256(question))`; without a repo the
commit is `none`. Rows: `briefs` (author vendor, body), `snapshots` (commit, diff hash, manifest) and the sitting's
`runs` row (`kind = sitting`) carrying `snapshot_id`; every `claims`, `assessments` and `verdicts` row of the sitting
carries it through `run_id`/`snapshot_id`. The copy of a finished seat run is removed as in U6d.

## Rounds and prompts

Each seat-round is a seat run through the same admission, budget (route key = council name), capacity, residency,
policy and confinement as an ask. Seats of a round run concurrently, subject to capacity. A seat that cannot be
admitted, is not usable, or is refused (residency, policy, budget, busy past its cap) is replaced by the next unused
`spare` that is not recused and passes the same checks; the flag `fallback_used` is set. With no spare left the seat
is `failed: <reason>` and does not vote.

Prompts are plain text, the first lines fixed:

```
ROUND: blind|rebuttal|challenge|synthesis
SITTING: <sit_id>
SEAT: <seat>
SNAPSHOT: <sn_id>
CHANGE KIND: <kind>
QUESTION:
<question>
```

followed by the answer-format text of docs/AGENT-API.md "Seat answer contract" (for `synthesis` the shape is
`{"summary": "..."}`), and for later rounds a labelled block, never instructions:

- **blind**: nothing from any other seat.
- **rebuttal** (default on): every other valid seat's claims, one per line,
  `CLAIM AG-<n>-<k> [seat <name>] <severity> <kind> <file>:<line>: <evidence>`; no votes, no notes. A seat receives
  only others' claims, never its own.
- **challenge** (off by default; runs only for disputed blockers): for each `p0`/`p1` claim with at least one
  `dispute` assessment, the claim line, then `  SUPPORT <seat>: <why>` and `  DISPUTE <seat>: <why>` lines. Only the
  seats that are not the claim's author receive it; answers carry `assessments` for those claims (claims ignored).
- **synthesis**: all claims (with backers and dissenters) and the final votes; run once on the first usable
  synthesizer.

Blind answers are stored (ledger rows, in the transaction that parses them) before any rebuttal prompt is built. A
blind prompt never contains another seat's text. Claim ids are global: `AG-<n>-<k>` where `n` is the sitting's
sequence number (1, 2, ... per ledger, also kept in the sitting row) and `k` counts claims in the order stored.

## Answer contract

The contract of docs/AGENT-API.md. The answer text is the trimmed output, or the single fenced json block in it.
Required: `vote` in `approve|block|abstain` and `claims` (a list, may be empty). Each claim: `id` (non-empty
string), `kind` in `defect|risk|question|note`, `severity` in `p0|p1|p2|p3`, `confidence` a number 0...1;
optional `file` (string), `line` (whole number >= 1), `evidence` (string, kept to 4096 bytes), `fix` (string).
`assessments` optional list of `{claim, stance: support|dispute|abstain, why?}`; an assessment naming an unknown claim
or the seat's own claim is dropped. Anything else that does not validate is a parse error with a one-line message.
First parse error: the seat is run again once, the same prompt plus the line `RETRY: 1` and the line
`ERROR: <message>`. Second error: the seat is `failed: unparsable` and is excluded from the vote count and from the
claims. A later round's answer replaces the seat's earlier vote and assessments (its claims from later rounds are
added). A seat that is unparsable in a later round is excluded entirely (earlier claims removed from the verdict).

## Silent seats

A running seat is silent when its run log and answer file have not grown for `silent_after * cap.seconds` seconds.
A silent seat is stopped and replaced by the next unused spare (flag `fallback_used`), else it is `abstained`
(reason `silent`) and does not vote.

## Votes, quorum, independence

Valid vote: the seat's latest answer is answered and parsed and its vote is not `abstain`. Convened seats `N` =
configured seats minus recused ones. Default quorum: `floor(N/2) + 1` valid votes and, when `len(seats) >= 2`, at
least two distinct vendors among the valid votes. An explicit `quorum` is exactly that many valid votes with no
vendor condition. Independence flags, in this order when set: `fallback_used`, `vendor_missing` (a vendor that was
convened has no valid vote), `single_vendor_quorum` (quorum met, `len(seats) >= 2`, all valid votes from one
vendor), `author_unknown`.

A claim is **backed** by its author and by every seat whose latest assessment is `support`; **disputed** by every seat
whose latest assessment is `dispute`. A claim is **refuted** when the distinct vendors disputing it outnumber the
distinct vendors backing it (a tie is not refuted); this is evaluated after the challenge round, or after the
rebuttal round when there is no challenge round. A claim is in the **minority report** when `2 * backers <= valid
votes`: each entry carries the claim id, `seat` and `vendor` of every backer.

## Verdict

The truth table of docs/PLAN.md U7, first match wins, exactly in that order, over: the synthesizer outcome (only when
a synthesizer is configured), the valid votes against quorum, `high_risk` with any flag, then the rule. For
`any_blocker` the blockers are the unrefuted `p0`/`p1` claims of non-excluded seats. `reasons` (list of strings)
names the row that decided: `synthesizer failed`, `quorum`, `independence: <flags>`, `blocker <claim id>`,
`no blocker`, `unanimous approve`, `majority approve`, `not unanimous`, `no majority`.

Verdict JSON (`result`, `sitting_verdict`, wake reply when done):

```
{"sitting", "council", "state": "done|pending|failed", "verdict": "PASS|BLOCK|INCOMPLETE", "reasons": [str],
 "rule", "high_risk", "snapshot": "sn_...", "author_vendor": str, "summary"?: str,
 "votes": [{"seat", "vendor", "state": "answered|failed|abstained|recused|refused", "vote"?, "valid": bool, "reason"?}],
 "claims": [{"id", "seat", "vendor", "kind", "severity", "confidence", "file"?, "line"?, "evidence"?, "fix"?,
             "backers": [seat], "dissenters": [seat], "refuted": bool, "minority": bool}],
 "minority": [{"claim", "seat", "vendor"}], "independence": ["flag"]}
```

Ledger: `claims` (id `AG-n-k`, `run_id` = sitting, `seat_run_id`), `assessments`, one `verdicts` row (verdict,
independence flags JSON, minority JSON, `snapshot_id`), `seat_runs` per seat-round. A sitting that cannot reach any
of the above because every seat failed ends `done` with `INCOMPLETE` (reason `quorum`), never `failed`; `failed` is
only a stopped or internally broken sitting.

## Triggers (U7b)

A trigger wakes a council by itself. Config key `triggers` (in `config.json`, validated like `councils`; any invalid
entry makes the whole config invalid, error text names the trigger):

```
{"name": str, "council": council-name, "repo": abs path of a git work tree,
 "paths": [glob]?, "pr_label": str?, "schedule": "every <n>m" | "every <n>h"?,
 "debounce_seconds": int 0...86400 (default 300), "quiet_hours": "HH:MM-HH:MM"?,
 "change_kind": design|code|... (default "code"), "question": str (default "Review the change since the last sitting."),
 "author_vendor": str?}
```

`name` is unique and matches the council-name charset. At least one of `paths`, `pr_label`, `schedule` is required.
`council` must exist, `repo` must be absolute. `quiet_hours` is the Mac's local time and may wrap midnight
(`22:00-07:00`). A schedule is `every <n>m` or `every <n>h` with `n` in 1...10000.

Each trigger wakes its council as caller `trigger`, so a route from `trigger` (or `any`) to the council must exist; with no
route the wake is refused like any other and the attempt is recorded (`refused`), never silently skipped.

### Evaluation

The broker evaluates all triggers every 30 seconds (`AGENCIL_TRIGGER_SECONDS` overrides it under
`AGENCIL_TEST_SEAMS=1`) and, under the same seam, on the op `tick` with optional `now` (ISO 8601 UTC) which evaluates once
at that instant and replies `{"fired": [{"trigger", "council", "key", "sitting"}], "deferred": [{"trigger", "reason"}]}`.
Evaluation is serialised and every trigger is judged independently. Per trigger, in this order:

1. Find the candidate: `paths`, `pr_label` and `schedule` each yield at most one candidate per evaluation; a trigger with
   several kinds fires at most once per evaluation (first kind in the order paths, pr_label, schedule).
2. If its previous sitting is still running: deferred, reason `running`.
3. If inside `quiet_hours`: deferred, reason `quiet_hours`.
4. If less than `debounce_seconds` have passed since the trigger last fired: deferred, reason `debounce`.
5. Otherwise it fires: the candidate's state is consumed first (one transaction), then the wake is made. A refused
   or failed wake puts the state back exactly as it was and is recorded in `trigger_fires` with outcome `refused`/`failed`; the same
   candidate is tried again at the next evaluation after the debounce window.
A deferred candidate is never dropped: the state is not consumed, so one later fire covers everything that accumulated.

### Candidates

- **paths**: the first evaluation only records the repo's `HEAD` sha as the baseline (no fire). Later, when `HEAD` differs from the
  baseline and `git diff --name-only <baseline> <HEAD>` lists a file matching any glob, the candidate has key
  `<HEAD sha>`; the wake carries `repo`, `diff: "<baseline>..<HEAD>"`, and snapshots that HEAD. When `HEAD` moved but nothing matches, the baseline
  moves silently to the new `HEAD`. If the baseline commit no longer exists (rebase), the baseline resets to `HEAD` without firing.
  Globs: `*` matches within one path segment, `**` any number of segments, `?` one character; patterns match the whole
  repo-relative path.
- **pr_label**: `gh pr list --state open --label <label> --json number,headRefOid --limit 100` run with the repo as its working directory.
  Output that is not the expected JSON, a non-zero exit, a missing `gh` or a timeout (20 s) makes the trigger deferred with reason
  `gh_unavailable` (fail closed: no fire, no state change). A PR whose `headRefOid` is not the last one sat for that PR number
  (`pr:<number>` state) is a candidate with key `pr<number>@<headRefOid>`; the oldest number goes first and the rest wait for
  later evaluations. If the commit is not present in the repo, deferred with reason `commit_missing`. The wake snapshots that commit
  (the wake op accepts an optional `commit`, a full 40-hex sha that must resolve to a commit in the repo, else usage error) with
  `diff: "pr<number>@<first 12 of sha>"`. **No timestamp is ever a key**: `updatedAt`, label times and verdict labels
  are not read, so a sitting that labels the PR cannot cause another fire (Bton invariant 11); only a new head sha does.
- **schedule**: the first evaluation records the current time as the last fire (no fire). It is a candidate when `now - last >= interval`,
  key `schedule@<epoch seconds of now>`; consuming sets the last fire to `now` (never to a time anyone else moves).
  The wake carries `repo`, `diff: "HEAD"`, and snapshots HEAD.

### Ledger and surfaces

Migration 7: `trigger_state (trigger TEXT, key TEXT, value TEXT, PRIMARY KEY (trigger, key)) WITHOUT ROWID` (mutable) and
`trigger_fires (id TEXT PRIMARY KEY, trigger TEXT NOT NULL, key TEXT NOT NULL, outcome TEXT NOT NULL, sitting TEXT,
detail TEXT, fired_at TEXT NOT NULL)` (a rowid table so attempts have a stable order; rows are appended, never changed). State keys: `head` (paths baseline), `pr:<n>`,
`schedule`, `last_fire` (epoch seconds, set on an accepted wake). State survives a broker restart; a broker that restarts mid-way
never fires the same key twice, because the state is consumed before the wake; a broker that dies between the two loses that fire instead.

The op and CLI verb `triggers` list each trigger: `{"name", "council", "kinds": ["paths","pr_label","schedule"], "last_fired": iso|null,
"last_sitting": id|null}` (config order). `agencil triggers` exits 0; with no triggers it prints `none configured`.
A trigger never edits the repo, labels a PR or posts anywhere; the verdict is read with `result`.
