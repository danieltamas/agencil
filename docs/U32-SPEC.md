# U32 Two doors

The broker is reached by the app, the CLI, the MCP server and, in the field, by agents that run in their own sandboxes
(Claude Code's). A same-user process is not a security boundary, but a sandbox the owner chose to keep an agent in must
not hand it the owner's authority. Four defects of v0.4.1 are closed here: the owner label is only a claim, the
Claude Code sandbox integration opens the whole state directory, `ask` and `wake` read any file a caller names, and a
caller can follow or stop work that is not its own. The access switch is also enforced only in the MCP client.

## Behaviour

1. **Two sockets in the Agencil home, both mode 0600.**
   - `agencil.sock` (the owner door): unchanged; the app, the CLI and the launcher use it; it serves every operation.
   - `agent.sock` (the agent door): the MCP server uses it. It serves only `ping`, `ask`, `wake`, `result`, `status`,
     `stop` and `list_targets`. Any other operation is `refused: not served on the agent socket`, exit 3.
   - A request on the agent door whose `caller` is `owner` is `refused: the owner calls on the owner socket`, exit 3,
     unless it comes from a seat's own process: that one stays the seat that started it (docs/AGENT-API.md "Chains"),
     so the claim gains nothing.
   - A seat sandbox (Confinement) denies both. The broker removes both stale sockets at start.
2. **Access switch at the broker.** On either door, a request whose `caller` is not `owner` and that is one of `ask`,
   `wake`, `result`, `status`, `stop`, `list_targets` is `refused: agent access is off`, exit 3, unless `config.json`
   holds `agent_access` = `on` at the moment of the request. An unreadable config is a refusal.
3. **Claude Code's sandbox gets the agent door only.** `install-mcp claude` adds `~/.agencil/agent.sock` to
   `sandbox.network.allowUnixSockets` and no longer adds `sandbox.filesystem.allowWrite`. The old pair that Agencil
   itself recorded in `installed.json` (`~/.agencil/agencil.sock` and the `~/.agencil` write) is removed on the next
   install and on uninstall; an entry the owner had before is never removed. The audit's `sandbox blocks Agencil`
   drift names the agent socket only.
4. **The MCP server speaks to the agent door;** the CLI keeps the owner door for every verb it sends as the owner.
5. **Attachments and repos are bound to the caller.** For a request that names `files` or a `repo` and whose `caller` is not `owner`, every path in
   `files` and the `repo` must, after resolving links, lie inside the git top level of the peer process's working
   directory (read from the kernel, never from the request) and outside the credential folders `~/.ssh`, `~/.aws`,
   `~/.gnupg`, `~/.config/gh`, `~/.claude`, `~/.codex`, `~/.agencil` and `~/Library/Keychains`. A path outside, a
   working directory that cannot be read or is not in a git repository, or a link that leaves the repo, is
   `refused: file outside the caller's repo`, exit 3, and nothing is read. The owner is not restricted.
6. **Work belongs to its caller.** For a non-owner caller, `status`, `result`, `stop` and an `ask` that continues a thread require the
   thread's recorded caller to equal the request's `caller`, else `refused: not your thread`, exit 3. `stop` on a
   sitting requires the sitting's recorded caller (same refusal); `status` and `result` on a sitting stay open to any caller with
   access on, because an `agencil://sitting/<id>` link is how an owner shares one. The owner may read and stop anything.

## Acceptance

- A raw client on `agent.sock` sending `panel`, `detail`, `findings`, `costs`, `data`, `launch`, `adjudicate` or
  `prune` gets exit 3 and no data; the same client sending `ping` gets `ok`.
- A raw client on `agent.sock` with `caller: owner` is refused for every operation.
- With `agent_access` `off` (or absent), `ask`, `wake`, `result`, `status`, `stop` and `list_targets` with caller `a`
  are refused on both doors; with `on` and a route they behave as before; as `owner` on the owner door they are
  unaffected by the switch.
- `agent.sock` and `agencil.sock` both exist with mode 0600 after start, and neither survives a stop.
- `ask` as caller `a` with `files` naming a file outside the peer's git top level, a link out of it, or each credential
  folder is refused and the file is never opened (asserted by a fixture the broker could not have read without
  failing). A file inside the repo is attached. As `owner` an outside file is attached.
- A thread asked by caller `a` cannot be read, followed or stopped as caller `b` (`refused: not your thread`); `a` and
  `owner` can. A sitting woken by `a` can be read by `b` but not stopped by `b`.
- `install-mcp claude` against a settings file with the v0.4.1 pair that Agencil recorded leaves only
  `~/.agencil/agent.sock` in `allowUnixSockets`, removes the `allowWrite` entry it added, and keeps any entry the owner
  had before; `--uninstall` removes the agent socket entry it added.
- The MCP server's request reaches the broker on the agent door (a broker with only the owner door fails closed).
