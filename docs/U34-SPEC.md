# U34: confined seats that run

Every confined seat run on the owner's Mac has failed since confinement landed (docs/U6-SPEC.md "Confinement"):
four sandboxed Codex launches exited 1, and no confined launch ever answered. Three gaps, each reproduced with
`sandbox-exec` against a real run's profile:

1. **Linked executable.** An npm install's `bin/codex` is a link to `../lib/node_modules/@openai/codex/bin/codex.js`.
   The profile grants the directory of the link (`bin`), not what it points to, so Node cannot load the script
   (`Cannot find module`). Claude's `~/.local/bin/claude` links to `~/.local/share/claude/versions/<v>` the same way.
2. **No DNS.** The resolver socket is reached as `/var/run/mDNSResponder`; `/var` is a link to `/private/var` and
   neither the link nor the socket is readable, so no host name resolves inside the sandbox.
3. **A read-only harness home.** Codex will not start with `~/.codex` read-only (`failed to initialize in-process
   app-server client`). Writing the real `~/.codex` would let a steered seat plant `config.toml`, `hooks.json`, rules or
   skills that run unconfined the next time the owner uses Codex. Instead each Codex run gets its own home.

With all three closed, a confined `codex exec` answered, reading nothing of the real `~/.codex`.

Claude is out of scope for gap 3: its login lives in the Keychain under a name bound to its config directory, so a
fresh `CLAUDE_CONFIG_DIR` is logged out. Gaps 1 and 2 are closed for every harness.

## Behaviour

1. **The executable's real place is readable.** Besides the directory of `argv[0]` (as today), the profile grants
   `file-read*` on the directory of `argv[0]` with every link resolved, and, when that resolved path lies inside a
   `node_modules` directory, on the package root: the path up to and including the package directory after the last
   `node_modules/` segment (`@scope/name` for a scoped package, `name` otherwise). Nothing above the package root is
   granted beyond the ancestor metadata walk that exists today. A path that does not resolve adds nothing.
2. **A broad executable directory is never granted.** A directory from item 1 (including the unresolved directory of
   `argv[0]`) is replaced by read grants on the executable file itself (both spellings) when it is `/`, the home, an
   ancestor of the home, a directory that contains the Agencil home, a directory named `node_modules`, or a directory
   inside one of the home's `.ssh`, `.aws`, `.gnupg`, `.codex` or `.agencil`.
3. **The resolver is reachable.** The profile grants `file-read*` on the literals `/var`, `/private/var/run` and
   `/private/var/run/mDNSResponder`, and nothing else under `/private/var/run`.
4. **Codex runs with a home of its own.** For a confined `codex` seat the broker creates `<run>/home/.codex`
   (directories mode 0700), copies the owner's `~/.codex/auth.json` into it (mode 0600) when that file exists and is a
   regular file, and starts the seat with `CODEX_HOME=<run>/home/.codex`. The real `~/.codex` is no longer granted
   to a confined `codex` seat at all (no read, no write).
5. **Nothing comes back.** What the seat writes in its home, its login copy included, never reaches the owner's
   `~/.codex`. A run whose Codex refreshed its login may leave the owner's own copy needing a new login; that costs
   the owner a login, while a copy-back would let a seat swap in tokens the broker cannot verify (see Threat model).
6. **The run's home is removed** with the repo copy when the exchange ends, and with stranded copies at broker start.
7. Other harnesses keep their current config grants (`claude`, `opencode`, `hermes`).

## Threat model

- **Who acts:** the confined seat process, steered by whatever is in the repo copy and the prompt (assume hostile).
  No new op, socket or setting; the broker is the only writer of the profile and of the seat's home.
- **What the seat can reach:** read-only, the harness package it was started from (owner-installed code, no secrets)
  and the resolver socket (DNS was already implied by `(allow network*)`). Read-write, its own run directory, now
  including its own `CODEX_HOME` with a copy of the owner's Codex login. It could already read that login before this
  unit (the real `~/.codex` was readable); it now no longer reads the owner's Codex history, sessions, memories,
  config, rules, skills or hooks.
- **The executable path** comes from the broker's discovery of the owner's installs, never from the repo or a caller.
  Item 2 stops an odd install (a link into the home, a script directly in `node_modules`) from turning into a grant
  of the whole home or of every package.
- **No write path to the owner's home.** A copy-back of a refreshed login was considered and refused in review: the
  broker cannot prove that tokens a seat wrote belong to the owner's account (an unchanged `account_id` field is the
  seat's own claim), so a copy-back would let a hostile seat replace the owner's login with dead tokens or with
  another account's, routing the owner's later Codex sessions to it.
- **Fail closed:** a missing or unreadable login means the seat runs logged out and fails, never that the real home is
  granted; a failure to prepare the home fails the ask before launch.
- **Enforced at:** the broker (profile generation, home preparation and removal); the kernel sandbox applies the profile.

## Interfaces (fixed so tests can be written before the code)

- `Confinement.executableReads(_ executable: String) -> [String]`: the directories item 1 grants for `argv[0]`
  (the unresolved directory, the resolved directory, and the package root when there is one), resolved spellings,
  before item 2 is applied.
- `Confinement.profile(...)` keeps its signature; it applies item 2, and for `harness: "codex"` it no longer includes
  `<home>/.codex`.
- `enum SeatHome` in `Sources/AgencilCore/Seats/SeatHome.swift`:
  - `static func prepare(harness: String, runDirectory: URL, home: String) throws -> [String: String]?`
    returns nil for a harness with no per-run home; for `codex` it returns `["CODEX_HOME": <run>/home/.codex]`.
  - `static func remove(runDirectory: URL)` removes `<run>/home`.
- `home` is the value of `Confinement.home(environment:)` (the test seam `AGENCIL_TEST_SEAMS=1` plus `HOME`).

## Acceptance

- `executableReads` for a link `<root>/bin/tool` -> `../lib/node_modules/@scope/pkg/bin/tool.js` contains
  `<root>/bin` and `<root>/lib/node_modules/@scope/pkg`, and not `<root>/lib/node_modules` or `<root>/lib`; an unscoped
  `node_modules/pkg/bin/x.js` gives `.../node_modules/pkg`; a link to `<other>/versions/1.2.3` (no `node_modules`) gives
  `<other>/versions`; a plain file gives only its directory.
- With the test home `H`: the profile for an executable linked to `H/tool` has no `subpath` grant of `H` (or of any
  ancestor of `H`) and grants the file `H/tool`; the profile for a link to `<root>/node_modules/tool` has no `subpath`
  grant of `<root>/node_modules` and grants that file.
- The profile contains a `file-read*` grant for each of `/var`, `/private/var/run`, `/private/var/run/mDNSResponder`.
- Under the real sandbox (skipped where `sandbox-exec` cannot apply a profile), a process started through a link
  whose target lies in a `node_modules` package reads a file in that package's root; with the same profile it cannot
  read a sibling package next to it. A process connects to `/var/run/mDNSResponder`.
- For `harness: "codex"` the profile has no `.codex` path of the test home; for `claude` it still has `.claude`.
- `prepare` for `codex` creates `<run>/home/.codex` (0700) holding a byte-equal `auth.json` (0600) and returns
  `CODEX_HOME`; with no `auth.json` in the home it creates the directory and copies nothing; for `claude`, `opencode`
  and `hermes` it returns nil and creates nothing.
- Under the real sandbox, a confined process started with the prepared environment can write inside `$CODEX_HOME`
  and cannot read or write `<home>/.codex/auth.json`.
- A confined `codex` ask through the broker (stub harness) launches with `CODEX_HOME` under its run directory; the stub
  rewrites `$CODEX_HOME/auth.json`; after the exchange ends `<run>/home` no longer exists and the owner's
  `<home>/.codex/auth.json` is byte-equal to what it was before the ask.
