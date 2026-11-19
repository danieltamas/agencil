# U39: a confined Claude seat that is logged in

A Claude seat asked with a repo runs under the broker's sandbox (docs/U6-SPEC.md "Confinement"). It has never answered
on the owner's Mac. Two gaps, each reproduced with `sandbox-exec` against a real run's `confine.sb`:

1. **Temporary folder.** Claude ignores `TMPDIR` and makes `/tmp/claude-<uid>` at start. The profile denies writes
   outside the run directory, so the seat exits 1 with `EPERM: operation not permitted, mkdir '/tmp/claude-501'`.
   With `CLAUDE_CODE_TMPDIR` set to the run's `tmp` folder, Claude starts.
2. **No login.** Claude keeps its login in the owner's login Keychain, item `Claude Code-credentials`, and reads it
   through `/usr/bin/security`. The sandbox does not grant `~/Library/Keychains`, so the seat answers `Not logged in`.
   U34 left this gap open.

Granting the Keychain to the seat was refused: every item that trusts `/usr/bin/security` (gh and other CLI tokens)
would then be readable by anything the seat runs. Instead the broker reads the item and passes only the access token.

## Behaviour

1. **The temporary folder is the run's.** Every confined seat starts with `TMPDIR` and `CLAUDE_CODE_TMPDIR` set to
   `<run>/tmp`.
2. **The broker reads the login.** For a confined `claude` seat, before launch, the broker runs
   `/usr/bin/security find-generic-password -a <owner's login name> -s "Claude Code-credentials" -w` through the
   broker's process runner (`ProcessRunner`), with a 10 second deadline. The tool runs in its own process group. The
   whole group is killed when the tool exits or at the deadline; a tool still running at the deadline is a failure
   even if it would exit 0 after TERM. The account is required: an older item of the same service, under account
   `unknown`, can sit beside the live one, and without `-a` the tool may return it. The item is JSON; the broker takes
   `claudeAiOauth.accessToken`. Other fields (`refreshToken`, `mcpOAuth`) are not used.
3. **Only the access token reaches the seat.** The seat starts with `CLAUDE_CODE_OAUTH_TOKEN` set to that token. The
   refresh token and every other field stay in the broker's memory only for the parse.
4. **The broker never writes the token.** It travels in the launch request's `secret_env`, like `AGENCIL_CAP`. The
   broker never puts it in `env`, the ledger, a log, the run directory or a refusal message. What the seat itself
   prints or writes is its own output (see Threat model).
5. **An expired login stops the ask.** When `claudeAiOauth.expiresAt` (milliseconds since 1970) is less than 60
   seconds after the moment the read ends, the ask fails before launch with `failed: the Claude login has expired;
   use Claude once to refresh it, then ask again`. An item with no `expiresAt` is used as it is. An item whose
   `expiresAt` is present but is not a finite number (`null`, a string, a boolean) is not used (item 6).
6. **A missing login runs logged out.** When `security` fails, does not finish within the deadline, or prints no
   usable item, the seat starts with no token and answers `Not logged in`, as a Codex seat with no `auth.json` does.
   Output from a read that passed its deadline is never used. No wider grant is made.
7. **Other runs do not change.** A Claude seat asked without a repo is not confined and keeps its own Keychain login.
   The broker never gives the token it read to a seat on another harness.
8. **The file login is hidden.** Claude can also keep its login in `~/.claude/.credentials.json`, refresh token
   included, and the profile grants all of `~/.claude` for reading. The profile of a confined `claude` seat ends with
   a `(deny file-read* file-write* ...)` rule on that file in three spellings: as named, with links resolved, and as
   the resolved folder plus the file name. The third covers a file that is created after the profile is written in a
   `~/.claude` that is a link. The rest of `~/.claude` stays readable.
9. **A linked config folder stays readable through its link.** For each granted config path the profile also grants
   a `literal` read (never a `subpath`) of the spelling with its folder resolved and its last part kept, which is how
   the kernel names the link node itself.
   Without it, a home under a linked folder (`/tmp` is a link to `/private/tmp`) cannot open `~/.claude/settings.json`
   through the `~/.claude` link.

## Threat model

- **Who acts:** the confined Claude seat, steered by the repo copy and the prompt (assume hostile). No new op, socket or
  setting. A caller only names a seat; the broker's config decides that the seat is `claude` and confined.
- **What the seat gets:** the owner's Claude access token, scoped to inference and valid for hours. The seat already
  runs as the owner's Claude account, so during the run it gets no new authority. The new exposure is after the run: a
  seat that sends the token out (`(allow network*)` holds for Claude seats) can use it until it expires. This is less
  than Codex seats get today (a full `auth.json` with its refresh token). The refresh token never leaves the broker.
- **What the seat does with it:** a hostile seat can print the token into its answer or its error output, or write it
  under `<run>/tmp`. Answers reach the ledger, so the token can end up there. Redaction would not stop this, since the
  seat can encode the token. This is the same exposure as sending it out over the network, and it ends at expiry.
- **What else reads the token:** every process the seat starts inherits it: the owner's own Claude hooks, inside the
  same sandbox. No MCP server starts (`--strict-mcp-config` with no config).
- **Inherited environment (unchanged by this unit):** every seat inherits the broker's own environment. A broker
  started from a shell that has `CLAUDE_CODE_OAUTH_TOKEN` or an API key set passes it to every seat, on every harness.
  The app started from Finder or at login has neither.
- **The file login (fixed by item 8):** before this unit, a confined Claude seat could read the refresh token in
  `~/.claude/.credentials.json`. That token outlives any run. Item 8 removes the read.
- **The Keychain itself:** the seat gets no Keychain grant, so no other item becomes readable.
- **The ledger:** launch environments are stored in clear, so the token goes through `secret_env` only (item 4).
- **Fail closed:** an expired token stops the ask; an unreadable item gives a logged-out seat, never a wider grant.
- **Enforced at:** the broker (Keychain read, token parse, launch environment); the kernel sandbox applies the profile.

## Known limits

- **An exit seen late is accepted.** `ProcessRunner` polls; when its poll runs after the deadline and finds the tool
  already exited, the output is used. Rejecting it was tried and reverted: on a starved machine the poll runs seconds
  late, and tools that exited at once read as timeouts (no login, failed probes). The window is a tool that exits
  just after the deadline; its output is still a Keychain item the broker asked for, checked for expiry after the read.
- **A token can expire mid-answer.** The 60 second margin is far below a seat's time cap.

## Interfaces (fixed so tests can be written before the code)

- `enum ClaudeLogin` in `Sources/AgencilCore/Seats/ClaudeLogin.swift`:
  - `static func accessToken(item: Data, now: Date) throws -> String?`: the token from a Keychain item; nil when the
    item is not JSON or has no non-empty `claudeAiOauth.accessToken`; throws `Refusal` (message contains `expired`)
    for item 5.
  - `static func secretEnvironment(environment: [String: String], now: Date? = nil) throws -> [String: String]`:
    `["CLAUDE_CODE_OAUTH_TOKEN": token]`, or `[:]` for item 6. Nil `now` means the clock after the read.
  - Test seam: with `AGENCIL_TEST_SEAMS=1` the tool is `AGENCIL_TEST_SECURITY` (an executable path); with the seam on
    and no such path, nothing is read and the result is `[:]`. Tests never read the real Keychain.
- `Invocation.secretEnvironment: [String: String]` (default `[:]`): merged into the launch request's `secret_env`.

## Acceptance

- `accessToken` returns the token for an item with `expiresAt` one hour ahead; returns the token for an item with no
  `expiresAt`; returns nil for non-JSON bytes, for `{}` and for an empty `accessToken`; throws a `Refusal` whose
  message contains `expired` for `expiresAt` in the past and for `expiresAt` 30 seconds ahead.
- A confined `claude` ask through the broker (stub harness, `AGENCIL_TEST_SECURITY` a stub that prints an item with
  token `T`) launches with `CLAUDE_CODE_OAUTH_TOKEN` equal to `T` and `CLAUDE_CODE_TMPDIR` equal to `<run>/tmp`. After
  the exchange ends, the bytes of `agencil.sqlite` (and its `-wal`, when present), the broker's `logs/` and the run
  directory do not contain `T`.
- With the seam on and no `AGENCIL_TEST_SECURITY`, a confined `claude` ask launches with no `CLAUDE_CODE_OAUTH_TOKEN`.
- With the stub printing an item whose `expiresAt` is in the past, the ask fails with a reason that contains
  `expired`, and the stub harness never starts.
- A confined `codex` ask and an unconfined `claude` ask (no repo) launch with no `CLAUDE_CODE_OAUTH_TOKEN`, and the
  security stub is never run.
- `accessToken` returns nil for an item with a non-empty token and `expiresAt` equal to `null`, to `"1794721718236"`
  (a string), or to `true`.
- With the seam on, a security stub that prints a valid item and then sleeps 15 seconds before it exits 0 gives
  `[:]` from `secretEnvironment`, and the call returns in less than 14 seconds.
- `Confinement.profile` for `harness: "claude"` with test home `H` contains a `deny file-read*` rule that names
  `H/.claude/.credentials.json` and appears after every `allow file-read*` line; for `codex` it has no such rule.
- Under the real sandbox, with the `claude` profile, a process cannot read `H/.claude/.credentials.json` and can read
  `H/.claude/settings.json`.
- With `H/.claude` a link to a folder `D` and no `.credentials.json` in `D`, the `claude` profile's deny rule names
  `D/.credentials.json` (resolved spelling). Under the real sandbox, a file `D/.credentials.json` created after the
  profile is written cannot be read through `D/.credentials.json` or through `H/.claude/.credentials.json`.
- With the seam on, a security stub that prints a valid item, closes its stdout, and then sleeps 15 seconds before it
  exits 0 gives `[:]`, and the call returns in less than 14 seconds.
- With the seam on, a security stub that starts a background child that keeps stdout open and sleeps 30 seconds,
  then prints a valid item and exits 0, makes the call return in less than 14 seconds; the child is not alive 5
  seconds after the call returns.
