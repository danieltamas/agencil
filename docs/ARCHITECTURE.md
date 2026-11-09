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
   the minority report kept. Each round thread is an ordinary ask. A consult council (`SittingConsult`) runs a blind
   round and an anonymous review of the other positions instead, and records every seat's position with an
   AGREED, SPLIT or ANSWERED verdict (docs/U33-SPEC.md).
5. The ledger (`agencil.sqlite`, system `libsqlite3`) keeps threads, exchanges (with the harness and model that
   answered, tokens and cost), sittings, claims, assessments, reservations and preflights. Rows that record
   history are never rewritten.
6. `Panel` ops read the ledger for the app and the CLI: sittings, threads, details, outcomes, the leaderboard.
7. After a sitting, the owner's panel (peer pid, never an agent) can put a follow-up to the council that held it: the `followup` op asks every seat of that council on a per-seat thread (linked to the sitting through `thread_rounds` round `followup`), each seat shown the sitting's record as labelled evidence plus the owner's text and any attached files. The `costs` op aggregates every answered exchange by local day, project, council, seat, model and caller for the Costs pane; it reads the exchange's own cost columns, so costs outlive the retention prune.

## Confinement and who may call the broker

A seat that works on a repo copy runs under `sandbox-exec` (`Seats/Confinement.swift`): writes only in its run
directory, reads only the copy, its own harness config, where its executable's links lead (the npm package root at
most) and system paths, network allowed for the model API (with the resolver socket), and a last-match deny for Unix
sockets under the Agencil home, so it cannot reach the broker. A Codex seat reads nothing of the owner's `~/.codex`:
`Seats/SeatHome.swift` gives it a `CODEX_HOME` in the run directory holding a copy of the login, removed with the
run; nothing the seat writes there is copied back (docs/U34-SPEC.md). A seat without a repo copy is
not sandboxed, so the broker also refuses by ancestry: `Broker.handle` runs `attributeRoot` (the process-tree walk in
`Seats/Attribution.swift`) before every operation outside `seatOps`, and a descendant of a seat run, or a caller whose
ancestry cannot be established, is refused. `launch` runs an arbitrary argv outside every sandbox, so only a broker
started with `AGENCIL_TEST_SEAMS=1` serves it; seats are started inside the broker, never over the socket.

Two doors. The broker listens on `agencil.sock` (the owner door: everything, for the app, the CLI and your own
commands) and on `agent.sock` (the agent door, `Broker/BrokerDoors.swift`: only `ping`, `ask`, `wake`, `result`,
`status`, `stop` and `list_targets`, and never the label `owner`). The MCP server uses the agent door. The agent
access switch is checked by the broker on every agent call, not only by the MCP client. A thread belongs to the
caller that asked it and a sitting may be stopped only by the caller that woke it. For a caller that is not the owner,
`files` and `repo` are bound to the git top level of the caller's kernel-reported working directory, judged on the
descriptor that is opened, and credential locations are never attached. Claude Code's sandbox integration allows
only `agent.sock`.

## Sharing a record: `agencil://` links

`SittingLink` (`AgencilCore/Councils`) is the one place a record id and a link convert. `agencil://sitting/<sit_id>`
and `agencil://thread/<th_id>` are addresses, not a registered URL scheme: the panel's detail screens copy one with a
link button, and `MCPServer.call` turns a link into the bare id before the broker sees the request, so the broker's
checks are unchanged. A link is an address, not a credential and not a permission. Parsing fails closed:
extra path parts, a query, a fragment, credentials, a port or a mismatched id kind return the input unchanged, and an
unchanged value is never a routable id. The tools that take an id (`sitting_status`, `sitting_verdict`, `stop`) say so
in their descriptions, which is how an agent learns the form.

## Panel rendering

A detail screen is a lazy stack, so a sitting with many long answers lays out what is on screen. `Kit/LongText`
renders an answer or a record section as block Markdown through `Kit/MarkdownBlock`. The Kit imports no logic, so the
caller hands it the parser (`DetailPage.markdownItems`, over `MarkdownDocument`); `LongText` parses and styles once
per text, off the main actor, drops a result for text no longer shown, and until then shows only the opening prose.
It budgets 3,000 characters per block behind a Show the full text button, with a fenced code block counted at its
preview (8 lines, 600 characters, Show all lines, copy). Underscores outside code spans are literal, because agents
write paths, not emphasis. `Kit/Tokens.swift` holds the limits (`Size.longTextChars`, `Size.codePreviewLines`,
`Size.codePreviewChars`, `Size.placeholderChars`, `Size.clampLines`, `Size.clampChars`), because views name tokens
and never literals.
The Costs pane reads the ledger, so it survives the Data pane pruning old text.

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
