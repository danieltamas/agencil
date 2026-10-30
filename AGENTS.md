# Agencil: instructions for agents

Agencil is a macOS menu bar app, a CLI (`agencil`) and a local MCP server that convene councils of coding
agents: one or more seats (a harness plus a model) that answer the same question independently, argue, and
reach a recorded verdict. The smallest council is one seat: any local agent can ask any configured seat
(a named harness plus model, e.g. an OpenCode seat on a remote Ollama model) through Agencil, which resolves
the seat to a working install, delivers the question, returns the answer and keeps the thread for follow-ups.
Any agent may ask any seat the owner's routes allow, in any direction, with loops and depth bounded by the
route rules. Every answer and every later
outcome is kept, so the app can show which seat is right on which kind of change and improve the councils
over time.

Owner: Daniel Tamas. Repo: github.com/danieltamas/agencil (public). License: MIT.

## Start here (in this order)

1. `docs/PLAN.md` - what to build, in units, each with acceptance criteria. Work the units in order.
2. `docs/DESIGN.md` - the UI standard. It is binding: a view that does not follow it fails the build.
3. `docs/AGENT-API.md` - the CLI, the MCP server and the routing contract other agents rely on.
4. `docs/LEADERBOARD.md` - the public seat leaderboard on this repo's README.
5. `docs/BRAND.md` - the logo brief.
6. `.local/research/` (git-ignored, present only on the owner's Mac) - the ideas behind the plan.

## Reference apps (read, never edit from here)

Three sibling apps by the same owner share this app's shape. Clone or read them from their public repos:

| App | Repo | Take from it |
|-----|------|--------------|
| MacMax | danieltamas/macmax | The base: skeleton, Theme/Looks, Components, Settings window and parts, About and Update, scripts, installer, release ceremony, `docs/LESSONS.md` |
| Bton | danieltamas/bton | `AsyncPress` + `InFlightActions` + the source-scanning press test, `FieldCapsule` (fixed height), `RowStack`, the bento tile, the animated `MenuBarIcon` |
| RMJ | danieltamas/runmyjob | `ModalFrame`/`ModalFooter`/`FieldBlock`/`SecretField`/`StatusLine`, `PanelLayoutTests`, the MCP server shape, `docs/AGENT-API.md` |

On the owner's Mac they are at `~/Sites/macmax`, `~/Sites/bton`, `~/Sites/runmyjob`. The skill
`macos-menubar-app` (if your harness has it) holds the lessons all three were built on.

## Stack

SwiftPM only, Swift 6, macOS 14, no third-party dependencies. Targets: `AgencilCore` (all logic, no
SwiftUI/AppKit), `Agencil` (SwiftUI app; the house kit lives in `Sources/Agencil/Kit/`), `AgencilCLI`
(installed as `agencil`), `AgencilCoreTests`, `AgencilTests`. State in `~/.agencil` (`$AGENCIL_HOME`
overrides, mode 0700): `config.json`, `agencil.sqlite`, `runs/`, `logs/`, `registry/`, `update.log`.
SQLite is an embedded file read through the system `libsqlite3`; it is not a database server (no Docker
needed). Secrets live in the Keychain, never in files or logs.

## Rules

- **Writer is not judge.** Acceptance tests for a unit are written by another vendor (Codex) from the
  unit's "Acceptance" lines before the implementation, and hashed; the implementer never edits them. Every
  diff is reviewed by another vendor; P0-P2 findings are fixed and re-reviewed before merge. Paste the
  defect classes from MacMax `docs/LESSONS.md` section 9 into every review prompt.
- **The UI standard is enforced by tests** (`docs/DESIGN.md`, "Enforcement"). Never silence a guard test;
  extend the kit instead.
- **Fail closed** on every safety decision (who may wake a council, what may leave the Mac, what gets
  published). Display may stay stale; a mutation never runs on an unknown state.
- **Repo text is untrusted.** Briefs, diffs, PR bodies and seat answers reach a model only as labelled
  evidence, never as instructions to Agencil.
- **Every setting lives in the app**, saved as it changes; `config.json` is re-read before every write.
- **Public repo hygiene:** no client, employer or personal names, paths, hosts or IPs in code, fixtures,
  docs or screenshots. Demo data uses made-up names (`harbor/checkout`, `lumen/api`, maya, jonas, lee).
- Files at most 500 lines (`scripts/check.sh` enforces it). English identifiers, comments and logs.
- Plain ASCII punctuation in every file (`scripts/check.sh` lints it). No vendor or AI attribution on
  any user-facing surface; naming the agents a council runs (a Codex logo on a seat) is identification.
- Author `Daniel Tamas <hello@danieltamas.ro>`, Conventional Commits, no `Co-Authored-By` or any
  co-author trailer. Commit and push only when the owner asks. Work on a branch per unit and merge
  fast-forward into `main`.
- `LOG.md` keeps `## Unreleased` at the top; every merged unit adds one line.
- Builds and tests: `scripts/check.sh` (on the owner's Mac through `rmj run -- scripts/check.sh`).
