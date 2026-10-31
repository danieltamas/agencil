# Agencil

**Ask any coding agent, or convene a council of them, from the menu bar.**

Agencil is a macOS menu bar app, a CLI (`agencil`) and a local MCP server. A council is one or more seats (an agent
harness plus a model) that answer the same question independently, argue, and reach a recorded verdict. The smallest
council is one seat: any local agent can ask any configured seat through Agencil and keep the thread for follow-ups.

Status: pre-release. The plan and its units are in `docs/PLAN.md`.

## Install

Not released yet. Until 0.1.0, build from source (below).

## What it does

**Councils.** Seats of different vendors answer a brief blind, review each other, and a synthesizer writes one verdict
with the minority report and independence flags kept. A seat that wrote the change never judges it.

**Asks.** `agencil ask <seat> "<question>"` resolves the seat to a working install, delivers the question, returns the
answer and keeps the thread. Routes decide who may reach what; no route means refused.

**Outcomes.** Every finding is later confirmed or refuted by evidence, an adjudication seat or the owner. The app scores
each seat per kind of change, and the learn loop proposes council changes that you approve or roll back.

**Leaderboard.** An aggregate-only card of confirmed share (Wilson 95% interval), coverage, golden recall, median time
and cost per confirmed finding, published from the `leaderboard` branch. Self-reported from one owner's councils; it is
not a general benchmark. See `docs/LEADERBOARD.md`.

## For agents

The CLI and the MCP server are thin clients of one broker on a Unix socket. The contract (commands, envelope, exit
codes, routing) is `docs/AGENT-API.md`. `agencil install-mcp` registers the server with the harnesses it finds.

## Build from source

Requires macOS 14 and the Swift 6 toolchain; no third-party dependencies.

```
scripts/check.sh
```

builds, lints and runs every test suite.

## Privacy and security

- State lives in `~/.agencil` (mode 0700); secrets live in the Keychain, never in files or logs.
- Repo text, briefs, diffs and seat answers reach a model only as labelled evidence, never as instructions.
- What may leave the Mac is decided per seat (hosted or local-only routes) and fails closed.
- The leaderboard export reads aggregate counts only: no repo, path, claim text, brief, prompt, person or host.
  A model appears under its public name or an alias approved in this repository.

## License

MIT.
