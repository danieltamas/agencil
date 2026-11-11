# U35: Gemini seats (dropped)

**Dropped by the owner on 2026-11-10.** Google refuses Gemini CLI with a personal login (see "Findings" below), so
a Gemini seat could only run on a paid API key. Gemini CLI stays a found but not runnable harness; Google models
come through Antigravity (docs/U36-SPEC.md). This file is kept as the record of the findings and of the per-run home
design, which U36 reuses (items 2 to 6 below are the template U36 refers to).

`gemini` is a known harness kind (discovery finds it, `SeatConfig.harnesses` accepts it), but the resolver refuses
every Gemini seat with "gemini has no adapter". This unit gives it one, so a Gemini seat answers like a Claude or
Codex seat and onboarding (docs/U37-SPEC.md) can propose it.

Reference install: Gemini CLI 0.61 (`gemini --help`): `-p` runs one prompt headless and exits, `-m` picks the model,
`--approval-mode plan` is read-only, `-o json` prints one result object, `-e` limits extensions,
`--allowed-mcp-server-names` limits MCP servers. Login lives under `~/.gemini` (OAuth) or in `GEMINI_API_KEY`.

## Findings on the reference install (2026-11-10, Gemini CLI 0.61.0)

- **Personal Google login is refused by Google.** A run with the owner's OAuth login fails with `IneligibleTierError:
  This client is no longer supported for Gemini Code Assist for individuals. To continue using Gemini, please migrate
  to the Antigravity suite`. A Gemini CLI seat therefore runs only on `GEMINI_API_KEY` (plan `credit`) or Vertex;
  subscription use of Google models is Antigravity's (U36). Scope of this unit pending the owner's choice.
- **Home:** Gemini reads `GEMINI_CLI_HOME` in place of the user's home, so the seat's home is
  `GEMINI_CLI_HOME=<run>/home`, giving `<run>/home/.gemini`.
- **Trust downgrades plan mode.** In a folder Gemini does not trust it prints `Approval mode overridden to "default"
  because the current folder is not trusted`. The argv must carry `--skip-trust` so `plan` holds.
- **Settings are generated, never copied.** The owner's `~/.gemini/settings.json` can hold hooks (shell commands on
  agent events); the seat's home gets a settings file Agencil writes, holding only the auth method.

## Behaviour

1. **Adapter.** `Adapter.command` builds, for `harness: "gemini"`:
   `[exe, "-p", prompt, "-m", model, "--approval-mode", "plan", "-e", "none", "--allowed-mcp-server-names", "agencil-none"]`
   plus `["-o", "json"]` when `reportUsage`. The answer is stdout. The prompt is one argv element, never a shell string.
   Implementation first checks on the reference install that `-e none` loads no extension and that an unknown MCP
   name loads no server; if either flag does not do that, the per-run home (item 3) carries an empty settings file
   instead, and this line of the spec is amended before code.
2. **Policies.** `Adapter.enforces("gemini")` is `[.readOnlyFiles, .noNetworkTools, .noFurtherMCP]` only if item 1's
   check shows plan mode blocks file writes, shell and web fetch, and that no MCP server loads. Each policy the check
   does not prove is left out, so a route that needs it is refused (fail closed).
3. **Per-run home.** Like Codex in U34: `SeatHome.prepare(harness: "gemini", ...)` creates `<run>/home/.gemini`
   (0700), copies the owner's `~/.gemini/oauth_creds.json` and `google_accounts.json` when each is a regular file
   (0600), and returns the environment that points Gemini at that home (the variable is confirmed on the reference
   install; `HOME=<run>/home` is the fallback). The real `~/.gemini` is not granted to the seat. Nothing is copied
   back. A seat paid by `GEMINI_API_KEY` gets the key from the Keychain entry the owner set in Settings, never from a
   file.
4. **Usage.** `UsageFormat.geminiResult` reads the `-o json` object: the answer text, input and output tokens, and the
   model that answered. A missing field leaves that figure unknown, never zero.
5. **Resolver.** `installed` treats `gemini` like `claude`/`codex` (probe, pin, sign-in); "has no adapter" remains only
   for `aider` and `goose`.
6. **Presets and catalog.** One preset `gemini-pro` (harness `gemini`, vendor `google`, plan `subscription`, the
   current Pro model id from the model catalog at implementation time). The Models pane lists Gemini models for the
   `gemini` harness.
7. **Images.** `seesImages("gemini")` stays false in this unit.

## Threat model

- **Who acts:** the seat process, steered by the prompt and repo copy (assume hostile). No new op, socket or setting.
- **What it reaches:** read-only, the repo copy and the Gemini install; read-write, its run directory including its own
  Gemini home with a copy of the owner's Gemini login. It no longer reads the owner's Gemini history, settings,
  extensions, MCP config or the Antigravity data that shares `~/.gemini` (`~/.gemini/antigravity`).
- **Login copy-back refused**, for the reason in U34: the broker cannot prove that tokens a seat wrote are the owner's.
- **Fail closed:** a missing login runs the seat logged out and it fails with a sign-in reason; a home that cannot be
  prepared fails the ask before launch; an unproven policy is not claimed.
- **Enforced at:** the broker (argv, profile, home); the kernel sandbox applies the profile.

## Interfaces

- `Adapter.command` gains the `gemini` case; `Adapter.enforces("gemini")` as item 2 decides.
- `SeatHome.prepare(harness: "gemini", runDirectory:home:)` returns the environment of item 3.
- `UsageFormat.geminiResult` and its parser in `UsageCapture`.
- `SeatPreset.named("gemini-pro")`.

## Acceptance

- `Adapter.command` for a gemini seat has `-p` followed by the prompt as one element, `--approval-mode plan`, the
  model after `-m`, and `-o json` only when `reportUsage`.
- `Resolver.installed` for a gemini seat with a probed install returns success; for `aider` it still fails with
  "has no adapter".
- `SeatHome.prepare` for gemini creates `<run>/home/.gemini` (0700) with byte-equal copies (0600) of the two login
  files when present, copies nothing when absent, and returns the environment of item 3.
- Under the real sandbox, a confined process started with that environment cannot read `<home>/.gemini/settings.json`
  or `<home>/.gemini/antigravity/`.
- The usage parser reads tokens and the answer from a captured `-o json` object, and leaves cost unknown for an
  object without usage.
- A gemini ask through the broker with a stub harness answers, and afterwards `<run>/home` is gone and the owner's
  `~/.gemini/oauth_creds.json` is byte-equal to before.
