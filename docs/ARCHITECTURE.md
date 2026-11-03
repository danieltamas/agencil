# Architecture

Agencil is a macOS menu bar app, the `agencil` CLI and a local MCP server over one broker. SwiftPM, Swift 6,
macOS 14, no third-party dependencies.

## Targets

| Target | Holds |
|--------|-------|
| `AgencilCore` | All logic, no SwiftUI or AppKit: config, ledger, broker, seats, councils, panel ops, MCP, update |
| `Agencil` | The SwiftUI app: `Kit/` (house components), `Store/` (observable stores), `Views/` |
| `AgencilCLI` | `main.swift` only; installed as `Contents/Resources/agencil`, never in `Contents/MacOS` |
| `AgencilCoreTests`, `AgencilTests` | Acceptance, layout and guard tests |

## Data flow

1. A caller (the CLI, an MCP client, a trigger, the panel) sends a request to the broker over a Unix socket in
   `~/.agencil` (mode 0700; `$AGENCIL_HOME` overrides).
2. The broker identifies the caller (peer credentials and capability), finds a route in `config.json`, and
   refuses by default: unknown caller, no route, hop limit, residency, budget or a seat that fails preflight. The one exception is the owner's own panel: a wake from the app process itself (peer pid, no `as`) runs on a synthetic one-hop route, so a manual sitting needs no configured route. A wake carries attached files: text is inlined as labelled evidence, images are copied into each vision seat's run directory (Claude and Codex) and named as not shown to the other seats in the brief.
3. `Asks` resolves a seat (harness plus model) to a working install, admits it (capacity, memory, budget
   reservation), runs it in a confined process or an HTTP request, and records an exchange on a thread.
4. `Sitting` convenes a council: blind round, optional rebuttal and challenge, synthesis, and a verdict with
   the minority report kept. Each round thread is an ordinary ask.
5. The ledger (`agencil.sqlite`, system `libsqlite3`) keeps threads, exchanges (with the harness and model that
   answered, tokens and cost), sittings, claims, assessments, reservations and preflights. Rows that record
   history are never rewritten.
6. `Panel` ops read the ledger for the app and the CLI: sittings, threads, details, outcomes, the leaderboard.

## Contracts

- `docs/AGENT-API.md`: CLI verbs, the seven MCP tools, routing and exit codes.
- `docs/DESIGN.md`: the UI standard, enforced by layout and source-scanning tests.
- `LedgerSchema.swift`: an ordered list of migrations; a ledger only moves forward.
- Fail closed on every safety decision. Display may go stale; a mutation never runs on an unknown state.

## State and secrets

`config.json` (re-read before every write), `agencil.sqlite`, `runs/`, `logs/`, `registry/`, `update.log`.
Secrets live in the Keychain, never in files or logs. Repo text, briefs, diffs and seat answers reach a model
only as labelled evidence.

## Release

`scripts/release.sh` builds a reproducible ad hoc signed zip; `release` tags and publishes it; `install.sh`
installs it; `scripts/tap.sh` creates and pins the Homebrew cask in `danieltamas/homebrew-tap`, and `scripts/registry.sh` adds the Agencil entry to `danieltamas/registry` when it is missing.

The release refuses to go out unless the README opens with the launch film (`scripts/readme-video.sh`, in `.release.json`
`test`): a user-attachments URL on its own line, made by dragging `brag-output/agencil.mp4` into the GitHub editor.
