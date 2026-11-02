# U26: the Claude entry must run, and the Claude sandbox must let it

Two defects found on the owner's Mac: `agencil install-mcp claude` registered the command as the literal
`~/.local/bin/agencil`, which Claude Code starts without a shell, so the server never started; and a sandboxed
Claude session cannot write `~/.agencil` or reach `~/.agencil/agencil.sock`, so every `agencil` call from it fails.

## Behaviour
1. `install-mcp claude` runs `claude mcp add agencil --scope user -- <HOME>/.local/bin/agencil mcp --caller <caller>`
   with `<HOME>` the expanded home directory (the same string codex and opencode already get). `--dry-run` prints
   that expanded line.
2. The Claude audit (`AgentAccess.audit`) treats an entry whose command is the old `~/.local/bin/agencil` form as
   drift: `server entry does not match this app` (it already does, since only the expanded path matches).
3. Sandbox settings file: `<claude config dir>/settings.json`, where the claude config dir is
   `$AGENCIL_MCP_CONFIG_DIR/claude` when that variable is set, else `~/.claude`.
   When that file exists, parses as a JSON object and has `sandbox.enabled == true`, an install of the claude entry
   also ensures:
   - `sandbox.filesystem.allowWrite` contains `~/.agencil`;
   - `sandbox.network.allowUnixSockets` contains `~/.agencil/agencil.sock`.
   Both are appended only when missing (no duplicates), keep every other key and array element in place, and the file
   is written atomically with its mode kept. A missing file, a file that does not parse, or `sandbox.enabled` not
   true: nothing is written and no error is raised.
4. `--dry-run` prints the two sandbox lines it would add and writes nothing.
5. `install-mcp claude --uninstall` removes only the entries Agencil added (recorded in `installed.json` under
   `entries.claude.sandbox`, the file's existing `entries` wrapper, a list of `{key, value}` pairs); an entry the owner already had before the install is never
   recorded and never removed.
6. Audit: when the claude MCP entry is installed and the sandbox file is enabled but lacks either value, `drift`
   gains `sandbox blocks Agencil`. Fully allowed, sandbox off or file absent: no such drift.
7. `agencil install-mcp claude` run again after the sandbox values are removed by hand adds them again (repair).

## Acceptance
- A1: dry run prints the expanded command and no `~` in the add line; a real run's argv has `<HOME>/.local/bin/agencil` at index 6.
- A2: with a sandbox-enabled settings file holding other keys, install adds exactly the two values; every other key is byte-equal after re-serialisation of the parsed object.
- A3: installing twice leaves one copy of each value.
- A4: sandbox disabled, absent or unparsable: the file is untouched (bytes equal) and the install exits 0.
- A5: values the owner had before are not removed by uninstall; values Agencil added are.
- A6: audit reports `sandbox blocks Agencil` only in the case of item 6.
- A7: dry run leaves the settings file bytes equal.
