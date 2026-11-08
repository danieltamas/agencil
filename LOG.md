## 0.7.1 (2026-11-08)

- A failed Codex seat says why (the provider's own error, such as an unsupported model) instead of "Reading additional input from stdin...", and one failed version check no longer moves a seat onto an older copy of its harness for ten minutes.

## 0.7.0 (2026-11-06)

- Consult councils: set a council's Kind to consult and it answers a question instead of gating a change. Each seat gives one position with its confidence, reasoning, what would change it and questions back, then reviews the others' positions blind to who wrote them. The sitting ends AGREED, SPLIT or ANSWERED with every position kept apart, the minority named, and a synthesis that must cover every seat.

## 0.6.1 (2026-11-05)

- A seat installed with npm (Codex) runs on the Node it was installed with: a Mac where another Node comes first on PATH (an Intel Homebrew Node) no longer fails the seat with "codex exited with status 1".

## 0.6.0 (2026-11-05)

- Answers and questions in a thread or sitting are drawn as Markdown: headings, lists and fenced code show formatted instead of as raw text.
- A long code block shows its first 8 lines, one row per line, with "Show all lines" and a copy button that takes the whole code. The findings a seat writes after a pasted script now stay in view instead of hiding behind "Show the full text".
- Line breaks inside a paragraph are kept, and an underscore in a path (`src/__tests__/`) no longer turns the word bold.
- Opening a long answer no longer flashes thousands of characters of raw text while it is formatted.

## 0.5.0 (2026-11-04)

- Security: agents now reach Agencil through their own socket, `agent.sock`, that serves only ask, wake, result, status, stop and list_targets. Everything else (the panel, settings, budgets, launching) stays on the owner socket. An agent can no longer claim to be the owner.
- The agent access switch is enforced by the broker itself, so a raw client cannot get around it by skipping the MCP server.
- An agent can only follow, read or stop its own threads, and only stop sittings it woke. Reading a sitting through an `agencil://sitting/<id>` link still works for any agent with access on.
- Files and a repo that an agent attaches must be inside the git repository of its working directory and outside credential folders (.ssh, .aws, .config, Library/Application Support and similar). They are checked on the file that is actually opened.
- Claude Code's sandbox integration now allows only the agent socket and no longer opens the whole `~/.agencil` folder for writing. Run `agencil install-mcp claude` again (or just open the app) to remove the old entries Agencil had added; entries you had yourself are kept.
- Settings shows the agent socket status. A failure to open the second socket no longer leaves the first one listening.
- Behavior change: `agent_access` off now blocks agents at the broker; a client that used to work with it off through the CLI under a non-owner label is refused.

## 0.4.1 (2026-11-04)

- Security fix: a seat working in a sandbox could reach the broker's socket and ask it to start any command outside the sandbox. The broker no longer serves that request in a release build, seats that work on a repo copy can no longer connect to the broker's socket at all, and a process started by a seat is now refused on every operation except asking, waking, following and stopping its own work and listing what it may reach. Update from Settings, About, or run the install line again.

- Behavior change: because of the socket block, a seat that works on a repo copy can no longer call Agencil back to ask another seat (a chain that starts inside a seat). Asks from your own agents, the CLI and the app are unchanged, and so are chains from a seat that was asked without a repo.

- Corrected the notes of 0.4.0: an `agencil://` link is only an address for a record. It is not a permission, and it does not by itself limit what a caller can read.

## 0.4.0 (2026-11-04)

- Findings cards are easier to read: the suggested fix is body-size text limited to three lines with a Show more button, a claim raised on the question says so in words, the tab explains Confirm, Dismiss and Ask a seat, and Confirm is the accent button.

- Opening a large sitting no longer stalls the panel: the record is laid out lazily and each long answer parses its Markdown once, off the main thread, and shows its first 3,000 characters with a Show the full text button.

- A link button on a sitting or thread copies `agencil://sitting/<id>` (or `thread`) to share with another local agent; `sitting_status`, `sitting_verdict` and `stop` accept the link or the bare id. The link carries only the id and grants no access beyond the caller's route.

## 0.3.0 (2026-11-03)

- Every sitting ends with a written synthesis (U29): what the council concluded, where the seats agree and differ, and the next step, drawn as formatted Markdown above the sitting's brief and rounds, with a Copy as Markdown button for the whole record. A council with no synthesizer has its first answering seat write it; that one is best-effort and never changes the verdict. The memory export carries the synthesis.

- You can ask a finished sitting's seats follow-up questions (U30): the sitting's page ends with an Ask the council box pinned to the bottom, with a floating Ask button; it goes to every seat of the council that held the sitting, each answering on its own thread. Paste screenshots or files into it (Cmd-V, several at once) and they show as tiles. Each seat is shown the sitting's question, synthesis, each seat's last answer and the verdict as evidence; later questions continue each seat's thread. Answers are kept with their cost, and the thread shows in the Threads list.

- Settings has a Costs pane (U31): 30 bars of daily spend with a day's calls underneath, the same money by project, council, seat, model or caller over today, 7 days, 30 days or this month, and a Months card. It reads the ledger, so costs stay after the Data pane prunes old text, and calls with no recorded cost show as unpriced instead of as zero.

## 0.2.0 (2026-11-03)

- The Sittings tab has a New sitting button (a floating pill in the bottom corner, like New rule in RMJ; docs/DESIGN.md "Floating action" makes that the one place a tab creates things, and a guard test enforces it): pick a council and a kind, ask a question, attach files and start a sitting by hand; the sitting opens with its rounds and verdict as they arrive. A sitting you start yourself needs no route; `agencil wake` takes `--file` for attachments
- A new sitting takes screenshots: paste an image from the clipboard (Cmd-V or the Paste image button); Claude and Codex seats see it, other seats are told an image was attached and not shown
- The panel's pages (the list, a sitting or thread detail, the new sitting form) and the New sitting pill now move in and out with the same fade and spring as the rest of the house apps.

## 0.1.3 (2026-11-02)

- Asks to the Claude and Codex seats no longer fail when the agent is started from a Superset terminal: the seat runs the real harness instead of Superset's launcher script (which could not find it from inside the sandbox), and the sandbox can read /etc, so Codex no longer stops on its requirements file


## 0.1.2 (2026-11-02)

- The Claude entry is installed with the full path to the command (the literal ~ made Claude fail to start the server), and the Claude Code sandbox is allowed to write ~/.agencil and reach its socket; Settings, Agent access shows when the sandbox blocks it and repairs it
## 0.1.1 (2026-11-02)

- About shows a release install as a release: the 0.1.0 build was stamped as built from source, so About read "v0.1.0, built from source"; release builds now carry no source stamp
- The README opens with the launch film, and a release is refused until it does
- The release lists Agencil in the registry when it is missing

## 0.1.0 (2026-11-02)

First release. Agencil is a macOS menu bar app, the `agencil` CLI and a local MCP server that convene councils of coding agents on your own subscriptions: ask any configured seat (a harness plus a model), or wake a council that answers blind, argues, and records a verdict with the minority report kept. Install with `brew install --cask danieltamas/tap/agencil` or the curl installer.

- Every sitting is named for the question it asked, shows the vendor marks of the seats that sat, and sums the tokens and cost the harnesses report
- Threads and sittings keep the harness and model that actually answered, even after a seat is edited
- Residency is enforced before a seat is probed, and explicit probes honour hard budgets
- The build history of this first version follows.


- Every ask and sitting round records the tokens in and out and the cost its harness reports (claude and opencode JSON result, codex `--json` events), or the cost from the model price list when the model has one, flagged `estimated` (`estimated, subscription` on subscription seats); the thread and sitting detail show them instead of unknown, budgets are charged as before
- Settings > Agent access groups each agent in one card (vendor mark, route count, aligned MCP entry and Instructions rows): one fact drives the badge, detail and button (installed, not installed, drifted), the entry reads as command/args/caller instead of raw JSON or TOML, claude shows its config path, and the destructive chip is a quiet outline at fixed widths
- Settings > Models lists every model the harnesses (opencode, codex, Ollama endpoints, claude aliases), the LiteLLM price list (all providers, USD per million tokens, daily and manual refresh, a bad download keeps the cache) and the owner's own `custom_models` know, with vendor marks, a filter, harness chips and an Add model sheet; the seat sheet's Model field suggests from the same catalog and still takes any id
- The panel header's seat chip is coloured by state: green when every seat is up, red when one is down (amber when the only down seats are busy), grey when none are configured or unread; Settings > Seats entries open the Edit seat sheet again, with Re-check kept beside the chevron
- Settings > Agent access says how agents reach Agencil: the stdio command and the Unix socket (path, reachable now, owner only, copy), the seven MCP tools with when to use each (read from MCPSchemas), and per harness the MCP entry and the instruction paragraph (path, state, routes, Install/Add), with a refusal notice when the master switch is off; no hooks are involved
- Settings lists are editable: every row in Seats, Councils and Routes opens its sheet pre-filled (Edit seat/council/route) with Save and a confirmed Delete; `ConfigEditor` gains `update` and `remove` (refused with what still uses the object, keys the sheet has no field for are kept), the council sheet gains spare and synthesizer pickers and the seat sheet gains role, plan, vendor and hosted
- Seats row rebuilt: a vendor mark (template, tinted by the theme; Claude and OpenAI bundled, a symbol for the rest) beside the seat name, the full model id wrapping with harness, plan and `alias` as meta, the dot dropped for the band, the preflight reason in plain words when a seat is down; clicking a row opens Settings > Seats on that seat, which lists mark, model, harness version, plan and last preflight with a Re-check that probes it

- U25: seat preflight: every seat is checked before a council does any work (install, sign-in, `opencode models`, a one-line probe read for usage limit, no credit, model gone, busy, unreachable, timeout) and the standing is kept in the ledger for 10 minutes; `wake` refuses up front with every failed seat named, or seats an `ok` spare of a new vendor; `agencil preflight [--seats a,b] [--probe]` and the `preflight` op; seats carry a `plan` (subscription, credit, free, local) so a free seat never meets a dollar budget; `agencil seats presets` and `seats add --preset <name>` plus a Preset menu in the seat sheet; one opencode process at a time; seat runs now record exit 0 or 1 so participation and coverage score (an unavailable seat is not a run)
- Settings > More apps and About are MacMax's panes: the registry cards (bundled snapshot offline, a fresh read at most hourly, installed copy by bundle id, standing, install line with copy) and About with the version line from AgencilSource, the standing against the latest release, Update through the bundled installer, Why it exists and Made by; both render in `--render-screenshots`
- UI pass (in progress): every panel tab is the same height (the tallest that fits the screen, at most 780), the search field and rows share the panel inset, thread rows reserve the accent slot so their text aligns, the footer offers "Star on GitHub" (the owner's own gh, remembered in config.json as starred_repo)
- U24: outcomes get real evidence and adjudication: the broker scans the git history of repos councils sat on (every 10 minutes, read-only, no user git config) for fix and revert commits that name a finding, and `agencil adjudicate <claim-id>` (Ask a seat on a panel finding) asks a seat of an independent vendor to weigh the evidence and records its answer
- U23: the learn loop reviews: `agencil learn review <id>` (and Review on the panel proposal row) asks the seat of another vendor through the ordinary ask path, reads ENDORSE or OBJECT from its first word and records the verdict and note; Approve follows an endorsement
- U22: the learn loop is decidable: `proposals` and owner `learn approve|reject|rollback` ops and CLI verbs, proposal rows with Reject, Approve (after an endorsing review) and Roll back on the panel Seats tab; the panel proposal count now counts the statuses the loop writes
- U21: the panel Findings tab decides: Confirm and Dismiss on every open finding call the owner `dispose` op once and refresh
- U20: schedulers (the broker runs, once a minute and each gated by its own last run: daily raw-output prune, memory export every 10 minutes, the learn loop weekly, and the enabled leaderboard publish after 06:00 or after 10 new outcomes; a failed job waits an hour and shows its error in `data`)
- U19: the placeholder Settings panes are real (Harnesses with re-check, Models, Budgets with add and remove, Scoring rules, Leaderboard repo, minimum and Preview or Publish now, Data with retention days, size readout, delete old raw output and memory export repos, More apps); `data` and `prune` broker ops
- U18: the broker lists are real (`seats`, `councils`, `routes`, `models`, `list_targets` gated by the caller's routes and the agent access switch, `findings [--open]`, owner `dispose confirm|dismiss`, owner `leaderboard preview|publish`); replies carry no endpoint, pin or key
- U17: agent access you can audit (a marked instruction paragraph per harness that tells agents when to use Agencil, installed and removed without touching other text; `agencil access` and the Agent access pane show server entry, instructions, routes and drift per harness; `agencil install-instructions`)
- U15b: `agencil wake --seats a,b --cap N` narrows one sitting to some of the council seats and shortens their caps (never lengthens), and scripts/council-wrapper.sh offers the old council.sh interface over wake with one report file per seat
- U15a: `agencil harnesses [--probe]` reports every catalog harness (found, path, version, signed in, probe status, chain support) from a cached or fresh probe
- U15 (part): fixtures of the existing council script on stub seats under Tests/Fixtures/council-script/, a replay harness that diffs any council script against them, and docs/U15-SPEC.md on what the wrapper needs from the engine
- README: product page (install pending the 0.1.0 release, features, for agents, build, privacy and security)
- U14: seat leaderboard (an aggregate-only export of confirmed share with Wilson intervals, coverage, golden recall, median time and cost per confirmed finding per model, harness and change kind, dropped below 20 outcomes and for any model not on the public list or an approved alias; a validator shared by the app and CI; the app writes only data.json on the leaderboard branch and starts the render workflow, which renders the card and LEADERBOARD.md from trusted code; publishing stays off until the first manual press)
- U13: data and memory export (raw seat output - run files and the question and answer of finished exchanges - is deleted after 90 days by default, never the files of a seat still running, while claims, evidence, verdicts and outcomes are kept; ledger size readout; each finished sitting of a repo turned on is written once as Markdown to that repo's memory folder, idempotent, untrusted text always fenced)
- U12: learn loop (proposals to drop, swap or add a seat or try one prompt variable only from 20 or more decided findings per cell, a drop only when the Wilson upper bound of the confirmed share is under 30%, a different-vendor seat reviews every proposal, nothing reaches config.json without the owner's approval, which writes a hashed council version in one step with the ledger and can be rolled back exactly)
- U11: outcomes and scoring (commit and PR text records fix-commit, revert and pr-dismissal evidence that never labels; an adjudication seat of a vendor that neither raised nor synthesized labels it, `cannot tell` stays pending, the owner's Confirm or Dismiss is final over a whole finding; 30 days without an event is unresolved; duplicate claims form one finding credited once per seat; confirmed share, coverage, participation, cost and median time per seat and council with Wilson intervals; recall exists only on the golden set, with the probation gate for voting seats; scoreboard over 10k claims in about 45 ms)
- U10: visual layer (SynapseScript decides one burst per event, once; Core Animation council ring in the in-session tile that stops with the panel and cross-fades under Reduce Motion; 14-frame menu bar synapse at 8 fps only while live, stopped on sleep and lock; backdrop mesh at 4% in the agencil look; `scripts/perf.sh` enforces the CPU budgets).
- U9: settings (seats, councils and routes created from sheets that validate the whole config and write it atomically, scalars saved as they change, notification kinds, seats at once, Agent access switch plus per-harness MCP install read back from the harness file; the broker picks edits up without a restart).
- U7a: sittings (wake_council runs a numbered sitting: frozen snapshot of the commit and tracked changes, blind then optional rebuttal, challenge and synthesis rounds, spares for unplaceable or silent seats, recusal by author vendor, quorum, independence flags, refutation by distinct vendors, PASS/BLOCK/INCOMPLETE verdict with minority report, stop, status and restart reconcile, sittings and verdicts in the ledger).
- U7b: triggers (paths, pr_label via gh, schedule; deferral order running, quiet hours, debounce; state consumed before the wake and restored on refusal, source errors defer instead of firing, pinned-commit wake, `agencil triggers`).
- U8: panel (live `panel` read of threads, sittings, findings, seats and week spend; bento counts only what needs the owner; notifications on verdict, BLOCK, seat down, 80% budget and failed thread, never on the first read; Stop shows "Stopping..." at once and presses once; `notify` config key).
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
