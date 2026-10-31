## Unreleased

- U6d: confinement and residency (seats[].hosted, routes[].residency and requires checked per candidate before a reservation, ask --repo exports HEAD to a per-run copy removed on every exit, redaction of secret-named, ignored and credential-bearing files and attachments for hosted seats, sandbox-exec profile that denies everything outside the copy and run directory and fails closed, attachments as briefs under .agencil/briefs).

- U6c: budgets and capacity (hard and estimated budgets by route, root and vendor, atomic reservations that survive a restart, bounded Ollama worst case, usage reconciliation, seats-at-once with parked ancestors, process cap, memory floor, `budgets` op and CLI verb). Seats now start in their own session.

- U6b: chains (per-run capability hashed in the ledger, process-tree attribution through the socket peer pid, hop limit, cycle, replay and impersonation refusals, `chain` in ask and result).

- U6a: seats, routes and ask (validated seat/route/alias config, resolver with fallbacks, codex/claude/opencode/hermes/ollama adapters, threads with follow-ups, result/status/stop). Known follow-up for U6b: pick the newest install that satisfies the pin, not the globally newest.
- UI preview (pulled ahead of U8/U9): panel with bento, tab island and four tabs, Settings window with 13 panes and a New sheet, all on demo data; screenshots render them.

- U0: skeleton and ceremony (package, scripts, installer, CI, root docs).
- U3: core foundations (AgencilHome, ConfigStore, ProcessRunner, Ledger with numbered migrations).
- U4: harness discovery (catalog data, version, signed-in via status command, chain probe), Ollama discovery with digest history, endpoint policy, Keychain key presence.
- U2: house kit (tokens, three looks, components, async press, sheets, offscreen renderer, demo data) with source guards and layout tests.
- U5: broker (socket, lock, launcher handshake, recovery), CLI client verbs, MCP stdio server, install-mcp; MCP schemas live in code (the installed CLI has no bundle beside it).
