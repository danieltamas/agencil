# U24 - sitting-time wiring: commit evidence and adjudication

U11 stores evidence and adjudications but nothing feeds them. This unit reads real git history for fix and revert
evidence, and asks a seat of an independent vendor to adjudicate a finding when the owner presses the button.

## Commit evidence scan (Sources/AgencilCore/Outcomes/CommitScan.swift)

- `CommitScan(ledger:directory:)` with `run(now:) throws -> Int` (the number of evidence rows offered to `recordCommit`).
- Repos are the distinct non-null `sittings.repo` paths whose directory still exists. Git runs through `RepoCopy.data`
  (no user or system git config, 30 s deadline), read-only: `rev-parse`, `log`, `show -s`. Nothing is fetched.
- Per repo the scan keeps the last head it covered in `evidence-scan.json` (mode 0600, repo path -> head sha). First scan
  of a repo: commits of the last 30 days, at most 200. Later scans: `<last>..HEAD`, at most 200, oldest first; a last head
  that is no longer an ancestor (rewritten history) falls back to the first-scan rule. The stored head moves to the
  current HEAD only after every commit of the batch was offered. An unreadable state file means the first-scan rule.
- Each commit is offered as `recordCommit(sha:, body: full message, revertedBody:, at: now)`. For a message with a
  `This reverts commit <sha>` line, `revertedBody` is the full message of that commit read with `show -s` in the same
  repo (nil when it does not exist). Ids that name no claim record nothing (U11 rule), duplicates record once.
- A repo that is missing, not a git repo or has no commits is skipped and does not fail the others.
- Maintenance gets a job `evidence`, every 10 minutes, with the U20 retry and error rules.

## Adjudication (Sources/AgencilCore/Broker/BrokerAdjudicate.swift)

- Broker op `adjudicate` (owner only, `requireOwner`; config validated first). Request: `id` (a claim id), optional
  `wait_seconds` (default 600, at most 3600).
- Refused with exit 4 when the claim is unknown, already has an owner outcome, or has no evidence rows
  ("claim <id> has no evidence"); nothing is asked in those cases.
- The seat: the first seat of the config, in order, whose vendor differs from the vendor of the raising seat and from the
  vendor of every `synthesizers` seat of the sitting's council (OutcomeBook.adjudicator rules; the council is
  `sittings.council` of the claim's sitting, an unknown council or vendor fails closed with exit 4).
- The question is built by Agencil: the claim body, kind, severity, file and line, and each evidence row (source and
  detail), as labelled evidence, then "Reply with CONFIRMED, REFUTED or CANNOT TELL on the first line, then one short
  reason." It goes through `ask` as the owner with `target` = that seat; the answer must come from that seat, not a
  substitute, and `config.json` must not change during the ask (U23 rules). One adjudication per claim at a time.
- The first words of the answer, uppercased, must be `CONFIRMED`, `REFUTED` or `CANNOT TELL` followed by end, whitespace,
  `:` or `.`. Anything else is exit 4 "the adjudicator gave no verdict". The rest is the reason (plain text, at most
  2000 characters). Recorded with `OutcomeBook.adjudicate(... certainty: "single-seat" ...)`. Pending -> exit 2, failed -> exit 4.
- Reply `{"id","adjudicator","answer","reason"}`.
- CLI `agencil adjudicate <claim-id> [--wait N]`. Panel: an open finding row shows an Ask a seat chip beside Dismiss and
  Confirm; a failure shows as the panel problem line.

## Acceptance

1. A temp git repo with a commit whose message names a known claim id gives one `fix-commit` evidence row with the
   commit sha; running the scan again adds nothing; a new commit naming it adds one more row.
2. A revert commit (`This reverts commit <sha>.` of a commit that names the claim) gives `revert` evidence for the claim.
3. A commit naming an unknown id, and a repo path that is missing, record nothing and do not fail the scan.
4. The first scan reads at most 200 commits and none older than 30 days; the stored head is the repo HEAD after a scan.
5. `run(now:)` through Maintenance includes `evidence` in the jobs that ran and `data` shows it.
6. `adjudicate` with a stub seat of a third vendor answering "CONFIRMED\nthe guard is missing" records an adjudication
   outcome (adjudicator = that seat, label confirmed) and the finding's status becomes confirmed.
7. `adjudicate` is exit 4 for an unknown claim, a claim without evidence and a claim the owner decided; exit 3 for a
   seat child; no seat of an independent vendor is exit 4; an answer with no verdict word is exit 4 and records nothing.
8. The question the seat receives labels the claim and evidence as evidence.
9. CLI parses `adjudicate <id> --wait 5`; `adjudicate` without an id is a usage error.

## Review follow-ups and known limits

- Git runs with signature display, fsmonitor and hooks turned off; the history is listed with `rev-list`, read with
  NUL-framed `log --no-walk` and checked sha by sha. A later scan takes the oldest 200 commits after the cursor and
  moves the cursor only through them; a failed read or revert lookup keeps the cursor and is retried by Maintenance.
- Adjudication reasons and review notes are scrubbed of credential-looking runs before they are stored or returned.
- Known limit: a pending adjudication (the seat is still running after `--wait`) does not hold the claim, so a second
  press asks again. Both answers are appended; the later one wins by the U11 status rules.
