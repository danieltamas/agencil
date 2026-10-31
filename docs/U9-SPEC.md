# U9 contract: Settings that write config the broker accepts

`docs/PLAN.md` U9 and `docs/DESIGN.md` "Settings" own the look. This file fixes what is not a view: how a sheet's
draft becomes config, when it is refused, how a scalar is written, and what "Install for X" shows. The logic lives in
`AgencilCore` (`Sources/AgencilCore/Settings/`) so it is tested without SwiftUI.

## ConfigEditor

`ConfigEditor(directory:)` (public), over the same `ConfigStore` the broker reads on every op. Each method re-reads
the file first, builds the new text of the one key it changes, validates the WHOLE resulting config with
`SeatConfig(values:)`, and only then writes, once, with `update(expectedRevision:)`. It returns the new
`ConfigSnapshot`. A refused call writes nothing and leaves the revision as it was.

- `add(_ seat: SeatDraft)`, `add(_ council: CouncilDraft)`, `add(_ route: RouteDraft)`.
- `set(_ key: String, _ value: String)` for scalars: `look` (one of the three look names), `notify` (a `NotifySettings`
  value), `limits` (a `Limits` value). An unknown key is refused. A value equal to the stored one writes nothing
  (the revision does not move). A scalar saved twice with different values is two writes.
- A refusal is `SheetProblems` (public `Error`, `Equatable`): `fields: [String: String]`, a message per field name.
  A problem that no field explains is reported under the key `form`.

Drafts (public, `Sendable`, plain values; the sheet fills them):

| Draft | Fields (the problem keys) | Becomes |
|-------|---------------------------|---------|
| `SeatDraft` | `name`, `harness`, `model`, `endpoint?`, `pin?`, `capSeconds?` | one object appended to `seats` (`cap.seconds` from `capSeconds`) |
| `CouncilDraft` | `name`, `seats` ([String]), `rule`, `quorum?` | one object appended to `councils` |
| `RouteDraft` | `callers` ([String]), `target`, `hopLimit?` | one object appended to `routes` |

- Field checks come first and name the field: an empty or badly formed `name`, a `name` already used by a seat or
  alias (seats) or council, an unknown `harness`, an empty `model`, `capSeconds` outside 1...3600, a council with
  no `seats` or a seat that is not configured, an unknown `rule`, `quorum` outside 1...seat count, a route with no
  `callers`, an empty `target` or one that is neither a seat, an alias nor a council, `hopLimit` outside 1...4.
- Then the whole-config validation is the safety net: any `ConfigProblem` it raises that the field checks missed
  comes back under `form` with its message.
- Existing keys and unrelated entries are kept byte-for-byte in meaning: the editor appends to the array, it never
  rewrites the other entries' values.
- Observable: after `add`, a running broker (no restart) accepts what the draft made (a seat can be asked, a council
  woken from a permitted route, a route is used).

## AgentAccess

`AgentAccess(home:, environment:)` (public) wraps the `install-mcp` machinery for the Agent access pane:

- `state(_ harness: String) -> AccessState`: `harness`, `installed: Bool`, `path: String?` (the harness config),
  `entry: String?` (the text of the `agencil` entry as it is in the file now), `problem: String?`.
- `install(_ harness:)` and `uninstall(_ harness:)` return the state read back from the file after the change. The
  read-back is a fresh read of the harness config, never the text the installer meant to write.
- A harness config that does not parse: `state` has `problem` naming the path and `installed == false`; `install`
  throws `AccessError(message:)` (public) and the file's bytes are unchanged.
- Supported harnesses are those of `install-mcp` (`claude`, `codex`, `opencode`); another name throws `AccessError`.

## Acceptance (observable)

- `ConfigEditor`: a valid seat, council and route sheet each produce config that `SeatConfig(values:)` accepts and a
  live broker uses without a restart; each invalid field is reported under its own key and nothing is written
  (revision unchanged); concurrent edits (revision moved between read and write) are refused, not merged blindly.
- Scalar: `set("notify", ...)` changes the file once (revision +1) and the same value again changes nothing.
- `AgentAccess`: "Install for codex" writes the entry and `state` returns the entry as read from the file; uninstall
  restores the original bytes; an unparsable file is reported and untouched.
- Layout (`Tests/AgencilTests/Layout`): every pane and every sheet renders at 760 x 540 with no horizontal overflow
  (rendered width <= the window), in every look; a sheet that failed to save keeps its `ProblemText` rows; the
  longest names fit.

## Review follow-ups (accepted limits)

Fixed after the cross-vendor review: scalar saves validate the whole config, Settings resolves `AGENCIL_HOME`, notify and
limits edits apply inside the snapshot the write is checked against, and install presses share one in-flight guard.

Carried to later units, with the reason:
- Claude install state comes from the ownership record, not a read of Claude's own config; a pending record can authorize
  removing a replaced entry; `claude mcp` runs without a timeout; the install check is not bound to the rename. All four sit
  in the pre-U9 `McpInstaller` path and need its own unit.
- Config writes run on the main actor (a held `config.lock` can stall Settings briefly).
- Harnesses, Models, Budgets, Scoring, Leaderboard, Data and More apps stay placeholders until the units that own their data.
- The sidebar Restart button is inert until the app has a restart operation.
