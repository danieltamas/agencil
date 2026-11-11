# U37: first-run setup

A new owner today opens Settings and fills three empty sheets (seat, council, route) field by field. This unit adds
a Setup window with three steps that propose everything from what is installed, so the first useful council exists
after three presses. Everything it writes can still be edited in Settings, and the last screen says so.

Owner decisions (2026-11-10): every write waits for one press per step; Setup opens while the config has no seats
and can be run again from Settings; the default is a cross-vendor review council; all five harnesses (claude,
codex, opencode, gemini, antigravity) are detected; antigravity gets seats once U36 lands, gemini stays found but not runnable (U35 dropped: Google refuses Gemini CLI on a personal login).

## Behaviour

1. **When it opens.** At launch, when `config.json` has no seat (missing file included), Agencil opens the Setup
   window once per launch. Settings > General gets "Run setup again", which opens it any time. Closing it mid-way
   keeps what earlier steps wrote; nothing else marks it done.
2. **Step 1, Found on this Mac.** Nothing runs until the owner presses "Find agents" (then "Recheck"), which reads
   the broker's existing `harnesses` op with `probe: true`. One tile per proposed seat among claude, codex, opencode,
   gemini, antigravity: icon (`VendorMark`), model, harness and version, signed in or not. A failed read proposes
   nothing and shows the error. A result the broker carried over a failed probe reports its sign-in as unknown. States:
   - found, signed in, runnable: proposed seat pre-checked (name, model, plan from the harness's preset);
   - found, not signed in: unchecked, with the exact command to sign in and a Recheck chip;
   - found, no adapter (gemini, and antigravity before U36 or after a no-go): shown greyed with the reason;
   - not found: one line listing them, with "Add later in Settings".
   OpenCode proposes its free presets as separate tiles, the first one checked. Ollama is never auto-proposed (it
   needs an endpoint). "Create seats" writes the checked seats; a name already in the config is skipped, not renamed.
3. **Step 2, Council.** A canvas with the seats picked in step 1 (made now, or already in the config under that
   name) as draggable tiles on the left; a seat set up before and not picked never appears. One council card on the
   right, pre-filled: name `review` (`review-2` and up when taken), kind review, rule `any_blocker`, one seat per
   vendor (the first seat of each vendor), quorum = min(2, seats). Drag a tile onto the card or click it to add it; a
   press on a member's chip removes it (drag is never the only way). More councils are made in Settings. "Create
   council" writes it. Fewer than two seats: the step says a council needs two and offers Skip.
4. **Step 3, Routes.** Callers on the left: the detected agents that can ask Agencil (claude, codex, opencode, and
   gemini/antigravity once their access wiring exists). Targets on the right: the councils and seats just made. Each
   route is a drag from a caller onto a target (or a click on caller then target), shown as the caller's chip on the target's card (a press on the chip removes it). Pre-filled: every
   caller to the council from step 2. "Create routes" writes them. Agent access is not switched here: the step shows
   whether it is on and links to Settings > Agent access.
5. **Done.** Lists what was written, says "Change any of this in Settings > Seats, Councils and Routes", and offers
   "Open Settings" and "Close".
6. **Writes** go through `ConfigEditor.add(SeatDraft/CouncilDraft/RouteDraft)` exactly as the sheets do, so the same
   validation applies; config is re-read before each write. A refused write shows its reason under the step and the
   step does not advance.

## Threat model

- **Who acts:** only the owner, through the app's own window. No new broker op, socket, CLI command or MCP tool.
- **What is read:** the broker's existing `harnesses` op, only on the owner's "Find agents" or "Recheck" press, so
  opening the window (also at launch) runs no installed binary. No prompt is sent to any model.
- **What runs:** the binaries discovery finds on the owner's PATH and install directories are the owner's installs
  and run unconfined during those checks, as they do today. A hostile binary planted there already runs whenever the
  owner uses that harness; Setup adds no new way to plant or reach one. Confining version probes is out of scope.
- **What is written:** `config.json` only, through `ConfigEditor`, from fixed inputs: harness kinds from the catalog,
  names and models from `SeatPreset`, the owner's drags. No repo text or seat answer reaches any field.
- **A forged probe result** (a binary that lies about its version or sign-in) changes only what Setup proposes; the
  config fields still come from the fixed presets, and the seat runs through the same resolver, pin and sandbox as
  any seat.
- **Fail closed:** a failed read proposes nothing (the last good result is not reused) and shows the error; an
  unknown sign-in is never shown as signed in; a write error stops the step, and writes that landed before it stay
  and are reported.
- **Opens itself** at most once per launch, and only on a config that reads and holds no seat.

## Interfaces (fixed so tests can be written before the code)

In `Sources/AgencilCore/Settings/SetupPlan.swift` (pure, no I/O):

```swift
/// One row of the broker's `harnesses` op: `kind`, `found`, `version`, `signed_in` ("yes" | "no" | "unknown").
public struct HarnessFinding: Equatable, Sendable {
    public let kind: String; public let found: Bool; public let version: String?; public let signedIn: String
    public init(kind: String, found: Bool, version: String?, signedIn: String)
}
public struct ProposedSeat: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready                      // found, signed in (or no sign-in needed: opencode free presets)
        case unconfirmed                // found, sign-in "unknown": proposed, checked, marked "sign-in not confirmed"
        case signIn(command: String)    // found, signed out: unchecked; the command that signs in
        case noAdapter                  // found, Agencil cannot run it yet: shown greyed, never checked
    }
    public let draft: SeatDraft; public let state: State; public let checked: Bool
}
public struct SetupProposal: Equatable, Sendable {
    public let seats: [ProposedSeat]    // in `SetupPlan.kinds` order, presets in `SeatPreset.all` order
    public let missing: [String]        // kinds in `SetupPlan.kinds` not found, in that order
}
public enum SetupPlan {
    public static let kinds = ["claude", "codex", "opencode", "gemini", "antigravity"]
    public static func propose(_ findings: [HarnessFinding]) -> SetupProposal
    public static func council(_ seats: [SeatDraft]) -> CouncilDraft?
    public static func routes(callers: [String], council: String) -> [RouteDraft]
    public static func pending(_ seats: [SeatDraft], existing: Set<String>) -> [SeatDraft]
}
```

- `propose`: per kind, the presets of that harness from `SeatPreset.all` (claude -> `claude-opus`, codex ->
  `gpt-codex`, opencode -> every `opencode` preset with the first checked and the rest unchecked). A kind with no
  preset but found (gemini, antigravity today) gives one `noAdapter` seat named after the kind. Sign-in commands:
  claude `claude`, codex `codex login`, gemini `gemini`, antigravity `agy`. A finding for a kind outside `kinds` is
  ignored; a kind with no finding counts as missing.
- `Adapter.runs(_ harness: String) -> Bool` (in `Adapters.swift`): true for the harnesses `Adapter.command` builds a
  process for (`codex`, `claude`, `opencode`, `hermes`); `propose` gives `noAdapter` to a found kind it is false for.
- `council`: name `review`, mode `review`, rule `any_blocker`, the first seat of each distinct `vendor` in input order,
  quorum min(2, count); nil when that leaves fewer than two seats.
- `routes`: one `RouteDraft(callers: [caller], target: council)` per caller, in input order, duplicates dropped.
- `pending`: the drafts whose name is not in `existing`, in input order.
- App side (`Sources/Agencil/Store/SetupStore.swift`, `Sources/Agencil/Views/Setup/SetupView.swift`):
  - `@MainActor @Observable final class SetupStore` with `enum Step { case found, council, routes, done }`,
    `var step: Step`, `static func shouldOpen(values: [String: String]) -> Bool` (true when the config `values` have
    no seat, a missing or empty `seats` key included), and `static func demo(findings: [HarnessFinding]) -> SetupStore`
    (inert: no broker, no file; `step == .found` and the proposal already made from `findings`).
  - `struct SetupView: View { init(store: SetupStore) }`, laid out at `Size.setupWindow` (a new token).
  - A kit `DropTile` / `DropCard` pair (drag, drop and click), added to `docs/DESIGN.md` and the kit gallery.
  - Writes go through `SettingsStore`'s `ConfigEditor`.

## Acceptance

- `propose` with findings {claude found signed in "yes", codex found "no", opencode found "unknown", gemini found
  "yes", antigravity not found}: claude-opus `ready` checked; gpt-codex `signIn(command: "codex login")` unchecked;
  the opencode presets `ready` with only the first checked (opencode free presets need no sign-in); one gemini seat
  `noAdapter` unchecked; `missing == ["antigravity"]`.
- `propose` with claude found "unknown" gives claude-opus `unconfirmed` and checked.
- `propose` with no findings gives no seats and `missing == SetupPlan.kinds`; a finding of kind `aider` is ignored.
- `Adapter.runs` is true for codex, claude, opencode, hermes and false for gemini, aider, goose, ollama, antigravity.
- `council` over [claude-opus (anthropic), gpt-codex (openai), glm-free (zhipu), deepseek-free (deepseek)] gives
  seats [claude-opus, gpt-codex, glm-free, deepseek-free], quorum 2, rule `any_blocker`, mode `review`; over two seats
  of one vendor it returns nil; over one seat nil.
- `routes(callers: ["claude", "codex", "claude"], council: "review")` gives two routes, claude then codex.
- `pending` drops a draft whose name is in `existing` and keeps order.
- With a temp `AGENCIL_HOME`, writing `pending` seats then `council` then `routes` through `ConfigEditor.add` yields a
  config that `SeatConfig(values:)` parses, with an existing seat of the same name byte-unchanged.
- The Setup window renders at its fixed size in every look with 0, 1 and 5 findings, no `Text` below its ideal width
  except where DESIGN allows, and every control at 28 pt (layout tests as for the panes).
- The app opens Setup at launch with an empty config and does not with one seat (`SetupStore.shouldOpen(values:)`).
