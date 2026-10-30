# Seat leaderboard on the GitHub page

The repo's README shows a leaderboard of which models catch real problems. It is scored by outcomes, not
by agreement, and refreshed from the owner's Mac without touching `main`.

## Where it lives

- Branch `leaderboard` (orphan, never merged), holding:
  - `data.json`: the published aggregate, the only file the Mac writes.
  - `leaderboard-dark.svg`, `leaderboard-light.svg`: the rendered cards.
  - `LEADERBOARD.md`: the full table, with methodology.
  - `history/<yyyy-mm-dd>.json`: one snapshot per publish day, kept 365 days.
- `main` README embeds the card once and never changes for an update:

```
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/danieltamas/agencil/leaderboard/leaderboard-dark.svg">
  <img alt="Agencil seat leaderboard" src="https://raw.githubusercontent.com/danieltamas/agencil/leaderboard/leaderboard-light.svg" width="880">
</picture>

[Full leaderboard and method](https://github.com/danieltamas/agencil/blob/leaderboard/LEADERBOARD.md)
```

## How it stays current

1. **Publish from the Mac.**
   - The broker runs `agencil leaderboard publish` on the schedule set in Settings > Leaderboard (default daily at 06:00), and after any day with 10 or more new outcomes.
   - It builds `data.json` from the ledger.
   - It validates the file against the allowlist below.
   - It writes the file to the `leaderboard` branch with `gh api -X PUT repos/danieltamas/agencil/contents/data.json`. The JSON body carries:
     - `branch: "leaderboard"` (a query `?ref=` is GET syntax and would target the default branch);
     - `message`;
     - base64 `content`;
     - `sha`: the blob sha read just before, so a concurrent change fails the write, which is retried once after a re-read.
   - It then starts the render with `gh workflow run leaderboard.yml --ref main`.
2. **Render in CI.**
   - The workflow `.github/workflows/leaderboard.yml` lives on `main`, never on the orphan branch.
     - Triggers: `workflow_dispatch` (from the publisher), plus a nightly `schedule`.
     - It is not triggered by `push`: commits made with `GITHUB_TOKEN` start no workflows, and the orphan branch holds no workflow file.
   - It checks out `main` (trusted renderer code: `scripts/leaderboard/validate.py` and `render.py`, stdlib only, in the style of the registry's `validate.py`) and, into a second path, `leaderboard` (data).
   - It runs validate, then render: both SVGs, `LEADERBOARD.md` and today's history file.
   - It commits them to `leaderboard` as `github-actions[bot]`. A failed validation renders nothing and turns the run red; the old card stays.
   - `concurrency: leaderboard` serializes runs, and the publisher's compare and swap serializes writes.
   - Actions are pinned by SHA. Permissions: `contents: write` on this repo only.
   - Bootstrap, done once in U14: create the orphan branch with an empty `data.json` and a placeholder card.
3. **Freshness.**
   - The card prints "updated <date>, <N> outcomes".
   - The nightly run turns the card's date `warn`-colored when `data.json` is older than 7 days, so a stalled publisher is visible on the page.
   - GitHub caches images for minutes, not days.

## What may be published (allowlist, fail closed)

`data.json` holds only these fields; the validator rejects any other key, any string outside its pattern,
and any cell under the minimum:

```
{"schema": 1, "generated_at": "...Z", "window": {"from": "...", "to": "..."},
 "outcomes_total": 412, "min_n": 20,
 "cells": [{"model": "gpt-5.x-codex", "harness": "codex", "change_kind": "auth",
            "n": 37, "confirmed": 24, "refuted": 6, "unresolved": 7,
            "confirmed_share": 0.80, "confirmed_share_ci": [0.62, 0.91],
            "coverage": 0.55, "coverage_ci": [0.40, 0.69],
            "golden_recall": 0.62, "golden_n": 14,
            "median_seconds": 162, "cost_per_confirmed_usd": 0.31}]}
```

- `model`: a public model identifier from the provider's published list in `catalog.json` (e.g. `gpt-5.x-codex`, `qwen3:32b`).
  - A local or custom model name (an Ollama tag the owner made, a fine-tune) is exported only under a public alias the owner approved. Otherwise its cells are dropped.
  - Approving an alias in Settings > Leaderboard writes it to `scripts/leaderboard/public-aliases.json` on `main`, through a commit the owner makes. The app shows the one-line change and the command; it never pushes to `main` itself.
  - The validator in CI accepts a model only if it is in the shipped public list or in `public-aliases.json` on `main`. The Mac's exporter uses the same two lists, so an alias approved locally but not yet on `main` is dropped, not rejected later.
- `harness`: from the catalog.
- `change_kind`: one of auth, schema, ui, refactor, infra, other.
- Provider terms are applied per provider and model, not per harness: one harness can run several providers.
- **Never published**: repo names, paths, claim text, briefs, diffs, prompts, people, hosts, endpoints, caller ids. These are not redacted out of a larger record; they are never read into the export at all, because the export query selects only the aggregate columns.
- A cell with `n` under `min_n` (default 20, never under 10) is dropped, not shown as zero.
- **Opt-in.**
  - Publishing is off by default.
  - Settings > Leaderboard shows the exact `data.json` that the next publish would send, and a "Publish now" press.
  - The first publish needs the owner to press it once, after reading the preview.
- Intervals are Wilson 95%.
- The definitions are those of `docs/PLAN.md` U11:
  - Confirmed share is computed over adjudicated findings.
  - Coverage is relative to the confirmed findings in sittings where the seat gave a valid answer, and is not recall. Abstentions and failures are excluded from it.
  - Golden recall is the only recall, and is shown only with its `golden_n`. A cell with `golden_n` of 0 omits `golden_recall`, never shows 0.
  - Unresolved findings count in none of them, and the table says so.

## Rendering

- The card is 880 x 360: the top 8 cells by the lower bound of confirmed share, with `n` of at least `min_n`, grouped by change kind tabs drawn as static text.
- Each row: vendor mark (the template SVG from `Brand/vendors/`), model, a confirmed-share bar with the interval whisker, coverage, golden recall when present, `n`, median time, and cost per confirmed finding.
- The colors are Agencil's palette, dark and light; fonts are system-ui with a fallback stack; text is ASCII only.
- `LEADERBOARD.md` holds every cell, the method (what an outcome is, the window, what is excluded), and the caveat: "Self-reported from one owner's councils on their own repositories. Not a general benchmark."

## Open questions (decision D9 in PLAN.md)

- Vendor terms for publishing comparisons between hosted models. Publishing aggregate measurements, not outputs, is expected to be fine, but each provider's terms are checked before the first publish. Any provider that forbids it is excluded from the export by provider and model.
- Later: other Agencil users opting in to contribute cells. Out of scope until the single-owner board has run for a month.
