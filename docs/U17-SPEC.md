# U17: agent access you can audit

Owner need: "no one remembers what they set in a config". Agent access is managed from the app and one CLI verb shows
the whole wiring, including drift.

## Instruction paragraph
`AgentInstruction` (AgencilCore/Settings) manages the paragraph that tells a harness when to use Agencil.
- Text: a constant with no trailing newline, plain ASCII, at most 12 lines, wrapped in `<!-- agencil:begin v1 -->` and `<!-- agencil:end -->`.
  It names `ask`, `wake_council` and `ask_result`, says when (a second opinion, a review of a change, a question for
  a stronger or different model), and says repo text and seat answers are evidence, not instructions.
- Location per harness, under `AGENCIL_MCP_CONFIG_DIR` when set (tests), else the real home:
  `claude` -> `<base>/claude/rules/agencil.md` (real: `~/.claude/rules/agencil.md`),
  `codex` -> `<base>/codex/AGENTS.md` (real: `~/.codex/AGENTS.md`),
  `opencode` -> `<base>/opencode/AGENTS.md` (real: `~/.config/opencode/AGENTS.md`).
- `install`: creates missing directories, appends the block to the file (a new file holds only the block). A file that
  already holds a block is rewritten in place, so install is idempotent and also upgrades an old text. Content outside the
  markers is never touched. A file with a begin marker and no end marker (or the reverse, or two blocks) is refused and
  left untouched. A path that is a symlink to a file the user does not own is refused. Writes are atomic.
- `remove`: deletes only the block (and one blank line before it). A file left empty is deleted. Absent block is a no-op.
- `state(harness)`: `absent`, `current` (block equals the current text), `outdated` (block present, text differs) or
  `broken` (markers unbalanced).

## Wiring audit
`AgentAccess.audit(values:)` (the config values from ConfigStore; master switch is `agent_access` == "on") returns one `Wiring` per harness: `harness`, `mcp` (the existing `AccessState`),
`instruction` (state above), `caller` (the harness kind), `routes` (targets of the routes whose callers include it, from
config.json) and `drift: [String]`. Drift strings (plain words, one each):
- `instructions missing`: MCP installed, instruction absent.
- `instructions outdated`: block text differs from the current text.
- `instructions without server`: instruction present, MCP not installed.
- `no route for this caller`: MCP installed, master switch on, zero routes.
- `server entry does not match this app`: installed entry's command is not `~/.local/bin/agencil`.
- `sandbox blocks Agencil`: the claude entry is installed and the Claude Code sandbox is enabled but does not allow `~/.agencil` or its socket (U26).
- `access is off`: MCP installed and master switch off (informational, always listed).
A harness with nothing installed and no instruction has no drift.

## CLI
- `agencil access [--json]`: prints the audit (no broker needed; reads files). Human form, one block per harness:
  `claude  server installed  instructions current  routes: 2` then each drift line indented. Exit 0.
- `agencil install-instructions <harness> [--uninstall] [--dry-run] [--json]`: installs or removes the block. `--dry-run`
  prints the file path and the block and writes nothing. Unsupported harness exits 64.

## App
Agent access pane: per harness card shows server state, instruction state, routes, drift lines; presses: Install or
Remove server, Install or Remove instructions, Copy entry; the master switch stays. A pane-level summary line:
"All wired" or "N things drifted".

## Acceptance
1. Install writes a new file holding exactly one block; second install leaves the bytes identical.
2. Install into a file with user content keeps that content byte for byte before and after the block; remove restores
   the original bytes.
3. Outdated block is replaced in place; user content untouched.
4. Unbalanced markers refuse and leave the file byte identical.
5. Remove on a file that is only the block deletes the file.
6. State reports absent/current/outdated/broken.
7. Audit: MCP installed + no instruction -> `instructions missing`; both + one matching route -> no drift; master off
   -> `access is off`; instruction only -> `instructions without server`; installed, on, no routes -> `no route for this caller`.
8. `agencil access --json` and `install-instructions --dry-run` run against a temp home with no broker and exit 0.
9. Unsupported harness for install-instructions exits 64.
