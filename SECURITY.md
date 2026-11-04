# Security

## Reporting

Report a vulnerability privately through GitHub: Security > Report a vulnerability on
github.com/danieltamas/agencil. Do not open a public issue for it. Expect an answer within a week.

## What Agencil is trusted with

Agencil is built to run coding agents for you, so it is trusted with more than a viewer would be. Status
of each item is marked: **built** means it exists in this repository today, **planned** means it is in
`docs/PLAN.md` and not yet written.

- Starting local agent harnesses (Claude Code, Codex, OpenCode, Hermes) as you, with your credentials. **planned**
- Reading the repository a council is asked about, through a frozen copy of it. **planned**
- Sending that copy to a hosted model only after a sanitized copy is made (no `.git`, no secrets by the
  redaction rules) and only on a route that allows hosted seats. **planned**
- A local Unix socket (`~/.agencil/agencil.sock` for the owner, `~/.agencil/agent.sock` for agents, mode 0600) and an MCP server, off by default. **planned**
- Writing entries into other agents' config files, with a diff first and an exact-entry uninstall. **planned**
- API keys, kept in the macOS Keychain and never in files or logs. **planned**

Today the repository holds the app skeleton, the installer and the release scripts. The installer
(`install.sh`) copies `Agencil.app` and the `agencil` command, and removes only a bundle whose identifier
is `ro.danieltamas.agencil`. **built**

## Threat model

- Repository text, pull request bodies, diffs and seat answers are untrusted. They reach a model only as
  labelled evidence, never as instructions to Agencil.
- Safety decisions fail closed: who may wake a council, what may leave the Mac, what gets published.
- A process running as your user is not a security boundary. One that can reach the socket can call it;
  chain limits, root rate limits and budgets bound the damage but do not stop it.
- Seats run the harnesses' own code with your credentials. Agencil confines hosted seats and refuses a
  harness it cannot confine; it does not make a harness safe.

## Data kept on this Mac

Everything lives in `~/.agencil` (mode 0700): `config.json`, the ledger `agencil.sqlite`, `runs/`,
`logs/`, `registry/` and `update.log`. Nothing is sent anywhere unless a route sends a sanitized copy to a
hosted seat you configured, or you press publish for the leaderboard (off until you do). Remove it all with
`install.sh --uninstall --purge`.

## Updates

Releases are published with `SHA256SUMS`; the installer checks the archive against it. Release archives
signed ad hoc are byte-for-byte reproducible from the tag (`scripts/release.sh X.Y.Z --verify`).
