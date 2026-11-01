# Agencil design standard

This file is the UI contract. It is binding: the guard tests in "Enforcement" fail the build when a view
departs from it. When a screen needs something the kit does not have, add it to the kit (one component,
one job), document it here, then use it.

## Why a standard

The three sibling apps (MacMax, Bton, RMJ) started from one design system and drifted:

- Font sizes: 5 tokens, but 12 literal sizes in the views.
- Corner radii: 3 tokens, but 43 `cornerRadius:` literals in Bton.
- Controls on one row ended up 26, 28, 29, 30 and 31 pt tall.
- "Pick one of N" is done four different ways.
- Toggles come in three sizes.
- MacMax stores the look in two places, and both apps set the color scheme two different ways.
- Each DESIGN.md describes things the code does not have (RMJ's `RowStack`, MacMax's sheets and 5 tabs).

The mechanism every time: a written rule with no check. Bton fixed the same mechanism for presses by
making it a test (23 violations of the written rule, zero after the test). Agencil does that for the whole
UI from day one.

## Sources (what is copied from where)

| Piece | From | Note |
|-------|------|------|
| Skeleton, `Theme`, `Looks`, `Palette`, `Finish`, `Bezel`, `CapsuleRing`, `Chip`, `Eyebrow`, `PulseDot`, `GlyphDisc`, `IconButton`, `PillButton`, `EmptyState`, `RiseIn`, `HoverCard`, `AppControls`, `RelativeTime`, `PressStyle`, `RowPressStyle`, `pointingHandCursor`, `LinkButton`, `SwitchRow`, `CopyButton`, `StarOffer` | MacMax main | The base |
| `PaneHeader`, `SettingsRow`, `SettingsCard`, `RowDivider`, `SettingsMetrics`, `SegmentChip`, `GlassField`, `GlassEditor`, `MenuField`, `ProblemText`, Settings window and sidebar | MacMax main | The most stable Settings of the three |
| `AsyncPress`, `AsyncPillButton`, `AsyncIconButton`, `InFlightActions`, the source-scanning press test | Bton | The only way a press starts work. Adapted: `InFlightActions` moves into `Kit/` and reaches `AsyncPress` through the environment, so the kit has no dependency on the app store (Bton's reads `AppStore`) |
| `FieldCapsule` (fixed height), `SearchField`, `RowStack` (pages of 25), bento tile, `MenuBarIcon` | Bton | `FieldCapsule` goes from Bton's 30 pt to `Size.control` 28. `RowStack` moves into the kit. Bton's icon draws a static working state and a short 14-frame sync ripple; Agencil's live synapse cycle is new work built on that plumbing |
| `ModalFrame`, `ModalFooter`, `FieldBlock`, `SecretField`, `StatusLine`, `FloatingPill`, `Collapsible`, `PanelLayoutTests` | RMJ | Sheets and layout tests |
| Offscreen renderer: `NSHostingView` in a never-shown window + `cacheDisplay` | MacMax `ScreenshotRender.swift`, `docs/SCREENSHOTS.md` | Not `ImageRenderer`: it draws placeholder text fields |

Renames while copying:
- Brand tokens `teal` / `mint` become `accent`.
- `dialLight` / `blue` become `accent2`.
- `unassigned` becomes `warn`.
- The semantic aliases `ok`, `warn`, `crit`, `unknown`, `running` are the only signal names views may use.
- `StartingLabel` and other app-specific leftovers are not copied.

## Folder

- `Sources/Agencil/Kit/` holds every token, component, the press helper and `InFlightActions`.
  - It imports only SwiftUI, AppKit, QuartzCore and Foundation, never an `Agencil` model type.
  - It may later be extracted into a package the other apps share; that is decision D1 in `docs/PLAN.md`.
- `Sources/Agencil/Views/` composes kit components and never styles primitives itself.
- `Sources/Agencil/Store/` holds the store and its async work. The guards in "Enforcement" hold each folder to its role.

## Tokens

All in `Kit/Tokens.swift`. A view uses a token name, never a number.

### Type scale (`Font.house`)

| Token | Size, weight | Used for |
|-------|--------------|----------|
| `eyebrow` | 9.5 semibold, uppercase, tracking 1.4 | Section labels (via `Eyebrow` only) |
| `badge` | 10.5 semibold, monospaced digits | Chips, tab badges, footer |
| `meta` | 11 regular | Second lines, timestamps, details |
| `control` | 12 semibold | Button and segment titles |
| `body` | 12.5 regular | Settings rows, field text, paragraphs |
| `rowTitle` | 13 medium | List row titles, card titles |
| `header` | 15 semibold | Panel header name, hero headline |
| `sectionTitle` | 18 semibold | About name, modal subtitles |
| `modalTitle` | 20 semibold | `ModalFrame` title |
| `paneTitle` | 24 semibold | `PaneHeader` title |
| `statSmall` | 17 semibold rounded | Small bento tiles |
| `statValue` | 26 semibold rounded | Big bento tile |
| `mono` | 11.5 regular monospaced | Commands, ids, model versions |

### Radius (`Radius`)
`bezel` 3, `tile` 7, `row` 8, `control` 10, `smallCard` 14, `card` 16. Capsules use `Capsule()`.

### Spacing (`Space`)
`xxs` 2, `xs` 4, `s` 6, `m` 8, `l` 12, `xl` 16, `xxl` 22, `pane` 28.
- Panel horizontal inset: 14, which is a named constant `Space.panelInset`. The footer uses the same 14 (RMJ drifted to 16).

### Sizes (`Size`)

| Token | Value | Rule |
|-------|-------|------|
| `control` | 28 | Every interactive control that sits in a row: `PillButton`, `SegmentChip`, `FieldCapsule` (search, `GlassField`, `MenuField`, `SecretField`), `ChipButton`, `FloatingPill`. One height, fixed, measured by a test |
| `iconButton` | 28 | Circle buttons |
| `chip` | 20 | Non-interactive `Chip` |
| `tabIsland` | 34 | Inner height of the tab island |
| `settingsRow` | 34 | Minimum height of a settings row |
| `menuBarGlyph` | 18 | Template icon |
| `panelWidth` | 404 | The panel is exactly this wide in every tab and look |
| `panelMaxHeight` | 780 | Height is `min(780, visibleFrame.height - 40)` |
| `settingsMin` | 760 x 540 | Settings window; the sidebar is 196 |
| `modalWidth` | 520 | `ModalFrame` default |

### Opacity (`Theme.opacity`)
`faint` .04, `wash` .07, `tint` .14, `lift` .16, `ring` .5, `dim` .58. Views use these names for every
opacity; literal opacities live only in `Kit/`.

### Motion (`Motion`)
- Springs only: `spring` (0.42, 0.82), `snappy` (0.28, 0.86), `gentle` (0.7, 0.9).
- `RiseIn` delays 0.035 s per index, capped at index 10.
- The burst timings for the synapse layer are in "Visual layer".

### Color

Looks:
- `agencil`: dark, lit, finish `bezel`; the default.
- `solidGlass`: dark, not lit, finish `pane`.
- `solidGlassLight`: light, finish `pane`.

The look is stored in one place: `config.json` key `look`. `Appearance` reads it at launch and writes it
through the config store; no UserDefaults copy. One modifier, `.houseScheme()`, applies the color scheme
and the look to a root (panel, Settings, every sheet); nothing else sets `colorScheme`.

Agencil palette (dark). These values are the starting point; the logo unit may adjust `accent`,
`accent2` and `brand` to match the final icon, here and in the registry `hue` together:

| Token | Value | Token | Value |
|-------|-------|-------|-------|
| canvas | 090A12 | textPrimary | white .94 |
| canvasLift | 0F1020 | textSecondary | white .58 |
| core | 14152A | textTertiary | white .36 |
| coreHover | 1A1C35 | accent (synapse violet) | A98BFF |
| shell | white .035 | accent2 (spark amber) | F5C451 |
| hairline | white .075 | brand gradient | 6E56F8, A98BFF, FF9BD2 (bottomLeading to topTrailing) |
| highlight | white .11 | ok / warn / crit / unknown | 3EE0A8 / FF9F43 / FF6B6B / 8A97AD |

- `solidGlass` and `solidGlassLight` keep MacMax's values for every token except `accent`.
- `accent` in `solidGlass` is B9A2FF; in `solidGlassLight` it is 6A45D1, with `accent2` B07A00.
- `Backdrop` when lit: canvas, plus radial `accent` .16 at (0.1, -0.05) r260 and `accent2` .06 at (0.95, 0.02) r220.

Meaning hues (`Theme.color(for:)`, the only place hex appears outside `Palette`):
- Verdict: `PASS` ok, `BLOCK` crit, `INCOMPLETE` warn, `deliberating` accent.
- Seat state: answered ok, thinking accent, silent warn, failed crit, abstained unknown.
- Council types: each type gets one hue from a fixed set of 8 (`Theme.councilHue(index)`), chosen in its editor, never free hex.
- Vendor marks are template PDFs (Brand/vendors/*.svg from simple-icons, rendered by `scripts/render-icons.sh`). The fallback is an SF Symbol. No vendor colors.

## One component per job

| Job | Component | Never |
|-----|-----------|-------|
| Start any async work from a press | `AsyncPress` / `AsyncPillButton` / `AsyncIconButton` with a stable `id` | `Task {}` in a button closure |
| Primary or secondary action | `PillButton` (`prominent:`) | Ad hoc `Button` styling |
| Destructive or small inline action | `ChipButton` (`destructive:`) | Red text buttons |
| On/off | `SwitchRow` (whole row is the hit area) | Native `Toggle`, mini toggles |
| Pick one of 2 to 5 | Row of `SegmentChip` | `MenuField`, popovers |
| Pick one of 6 or more, or a dynamic list | `MenuField` | Native `Picker`, a bare `Menu` |
| Filter a list | Row of `SegmentChip` under the search field | `Chip` wrapped in a `Button` |
| Text, one line | `GlassField` (on `FieldCapsule`) | Native `TextField` styling |
| Secret | `SecretField` | Showing the value after save |
| Multi-line text, prompts | `GlassEditor` (monospaced for prompts) | |
| Search | `SearchField` (on `FieldCapsule`) | |
| Create or edit an object | `.houseSheet(item:)`: the kit's only sheet presenter. It wraps its content in `ModalFrame` + `ModalFooter` (Cancel, Create or Save) itself | `.sheet(` anywhere outside `Kit/`, a separate screen, inline Save buttons in a pane |
| A list | `RowStack` (25 per page, "Show N more", newest first) | Plain `VStack` of rows |
| A row that opens something | `HoverCard(accent:, action:)` | Rows without hover |
| Expand a row in place | `Collapsible` | |
| Empty or waiting list | `EmptyState` or `WaitingState` ("Reading seats...") | "Nothing here" before the first read |
| Status of an operation | `StatusLine(tone:)` | |
| Problem under a control | `ProblemText` | Alerts |
| Confirm a destructive press | Two-press `ChipButton` ("Press again to delete", 3 s) | Alerts, dialogs |
| Copy a command | `CopyButton` / `InstallLine` | |
| Count or state label | `Chip(style:)` | Colored text |
| Live state | `PulseDot` (Core Animation) | SwiftUI repeat animations |

### State colour

Every card carries the glow bar on its left edge in its state colour, finished or not. One function chooses it,
`PanelTone` (`Store/PanelTone.swift`); a row never picks a colour itself.

| State | Signal |
|-------|--------|
| asking, running, sitting, pending | `running` (blue) |
| answered, PASS, done, confirmed | `ok` (green) |
| failed, BLOCK, dismissed | `crit` (red) |
| stopped, INCOMPLETE, busy, needs you | `warn` (orange) |
| anything else | `unknown` (grey) |
| severity p0, p1 | `crit` |
| severity p2 | `warn` |
| severity p3 and lower | `unknown` |

The Seats row keeps its own band: `ok` while the seat can sit, `crit` when it cannot.

## Panel

`MenuBarExtra`, `.window` style, `Size.panelWidth`. From top to bottom:

1. **Header**, padded 14/14/10:
   - The 18 pt brand glyph, then "Agencil" in `header`.
   - The seat health `Chip`: `7/8 seats up`, `ollama-box down`, `no seats`.
   - `Spacer`.
   - The update `IconButton` when a newer release exists.
   - `AsyncIconButton` refresh (id `refresh`).
   - The gear.
   - `PulseDot` plus `N live`.
   - The order is fixed.
2. **Bento** (Bton's shape, height 140):
   - Big tile: `Eyebrow` "Needs you", then a `statValue` count of what a human must do (findings to decide, proposals to approve, councils that stopped incomplete). Chips jump to the tab.
   - While a council sits, the big tile becomes the **Council ring** (Visual layer), with the newest live sitting.
   - Right column, two small tiles: "Seats" (`up of total`, pulse when any is thinking) and "This week" (spend and the share of the weekly budget).
   - With no council configured, the bento explains the first step instead of showing 0.
3. **Tab island**, Bton's shape:
   - Tabs: **Threads**, **Sittings**, **Findings**, **Seats**, plus **Learn** after 0.1.0 (`docs/PLAN.md` U12).
   - Only the open tab shows its name; badges count only what matters.
   - The name falls back to icon-only when it does not fit, measured with `ViewThatFits`.
4. **Content**: a `SearchField`, then a filter row of `SegmentChip`s, then a `RowStack`.
5. **Footer**, padded 14/10, with a top hairline:
   - `StarOffer` until starred.
   - Poll ages: `probed 40s`, `ollama-box 12s`.
   - `AppControls` (Restart, Quit).

Tabs:
Under the tab island, one muted line says what the open tab is. Pressing a Thread, Sitting or Finding row pushes a
detail screen into the panel itself (a back chip, no window): the header and footer stay. A figure the ledger does
not hold reads `unknown`, never a guess.
- A **Thread** detail shows who asked and from which project, the seat and its model and harness, response time,
  tokens and cost, then the whole exchange: each question, each answer, the reason when it failed.
- A **Sitting** detail shows the brief, the verdict and its reasons, each seat's vote, every round with each seat's
  answer (and its time, cost and model), the claims, and the snapshot id. A seat's answer that is JSON is shown as
  labelled lines; raw JSON never reaches the UI.
- A sitting's per-round seat exchanges are stored as threads but belong to their sitting: the Threads list shows only
  direct asks.
- **Threads**: one-seat asks between agents. Each row shows:
  - The caller glyph, an arrow, the target seat.
  - The first line of the question and the state (`asking`, `answered 41s`, `failed: reason`).
  - Expanded: the full exchange with follow-ups, tokens, cost, and a "Continue in Terminal" button that opens the seat's session when the harness has one.
  - Filters: All, Live, Failed, Mine (asked by the owner).
- **Sittings**: councils of 2 or more seats, sections Live, Today, Yesterday, Earlier. Each row shows:
  - The council type chip in its hue, the target (repo#PR or brief title), and who woke it.
  - The state chip, the independence flag, elapsed time and cost.
  - Expanded: one line per seat (vendor mark, model and version, state), the claim timeline (Visual layer), the verdict with its minority report.
  - Presses: Stop, Rerun with other seats (shows the cost first), Open report, Copy verdict JSON.
- **Findings**: claims waiting for the owner's disposition.
  - Each row shows severity, `file:line`, the claim, backers and dissenters, and `minority` when it was.
  - Presses: Confirm, Dismiss, Will fix.
  - Outcomes from git attach as chips: `fixed in a1b2c3`, `reverted`, `unresolved 30d`.
- **Seats**: the scoreboard, with change-kind filter chips (All, Auth, Schema, UI, Refactor, Infra). Each row shows:
  - The vendor mark (`VendorMark`, a template tinted with a theme token), the seat name, and health as the accent band alone (no dot).
  - The full model id on its own line, wrapping, never cut; under it the harness, the plan and `alias` when the id is a short name. When the seat is down, its preflight reason in plain words (`usage limit until Nov 3`).
  - A click opens Settings > Seats with that seat marked.
  - Confirmed share and coverage, each with an interval; golden recall when the seat has golden-set runs (definitions in `docs/PLAN.md` U11; nothing outside the golden set is called recall).
  - Cost per confirmed finding, median time, the strongest overlap (`92% like kimi-k2`), and probation status.
  - A cell under the minimum count is grey and reads `n=7, too few`.
- **Learn**: proposals with evidence links and the other vendor's review; Approve, Reject.
  - Below them: the golden set status and the prompt versions with their before and after numbers.

Text at 404 pt (RMJ's rules):
- Labels are one line and never truncate.
- A repo or brief title wraps to a second line before anything truncates.
- Commands and model ids truncate in the middle, with the full text in the tooltip.
- Reasons wrap freely in the expansion and are one truncated line in the row's meta.

Menu bar icon:
- Idle: the 18 pt template glyph.
- Live: the animated synapse frames (Visual layer).
- A 6 pt `crit` badge when a sitting failed unseen, plus an optional count.
- No system colors: `Theme.crit`, not `.red`.

## Settings

The Settings window follows MacMax exactly:
- The `Settings` scene, `settingsMin`, `Backdrop`.
- Sidebar 196 on `canvas` .55: `Eyebrow` "Settings", rows with a 24 pt glyph tile (`Radius.tile`, pane hue .16 when selected) and a `body` label, the selected row on `core` (`Radius.control`) with a hairline, `AppControls` at the foot.
- Content scrolls, padding `Space.pane`, keyed by pane with the spring fade.
- The selected pane lives in the store, so any "Set up in Settings" press opens the right pane.

Every pane:
- `VStack(spacing: Space.xxl) { PaneHeader; SettingsCard... }`.
- A pane that lists objects puts a `PillButton("New ...")` at the trailing bottom of the header row. "New" and "Edit" open a sheet.
- Scalar settings save as they change. Only sheets have Save.

Panes, in order (symbol, hue):

| Pane | Symbol | Hue | Holds |
|------|--------|-----|-------|
| General | slider.horizontal.3 | accent | Look (3 `SegmentChip`s), Open at login, seats at once, free-memory floor, notifications (what fires), data folder |
| Seats | person.2.wave.2 | accent | The named seats: harness + model + endpoint + pinned version + hardening + per-seat cap; the list with health; "New seat" sheet |
| Councils | circle.hexagongrid | accent2 | Council types: seats, roles, quorum, rounds, verdict rule, recusal, caps, data residency, prompt (versioned), automatic triggers ("Wake on": paths, PR label, schedule) with debounce and quiet hours; "New council" sheet |
| Routes | arrow.triangle.branch | ok | Who may ask whom: caller -> seat or council, hop limit, depth, rate, quiet hours, budget per route; "New route" sheet |
| Harnesses | terminal | neutral | Detected harnesses (path, version, signed-in state, last probe, Probe now), hardening flags, the catalog of ones not installed |
| Models | cpu | memory hue | Hosted providers (key present yes/no, by Keychain name), Ollama endpoints local and remote (URL, health, loaded models, Pull), free-model change warnings |
| Budgets | gauge.with.dots.needle.50percent | warn | Weekly caps per vendor and per council type, alert thresholds, "Pause wakes at 90%" |
| Scoring | checkmark.seal | ok | Outcome sources, unresolved window, minimum n, golden set, composite metric, weekly proposal job and its reviewing seat |
| Leaderboard | chart.bar.xaxis | accent2 | Publish on/off (default off), schedule, the exact JSON that would be published, last publish result |
| Data | internaldrive | neutral | Ledger location and size, retention, export to a Bton memory folder per repo |
| Agent access | sparkles | accent | MCP server on/off (default off), per-harness install lines and "Install for X" presses, the CLI line, what each harness was told, recent MCP calls |
| More apps | square.grid.2x2 | memory hue | Registry cards (MacMax's pane, unchanged) |
| About | info.circle | neutral | MacMax's About: icon, version line with `AgencilSource`, standing, Update, Why it exists, Made by |

Sheets (`ModalFrame`, width 520):
- **New seat**: name; harness (`MenuField` of detected harnesses); model (`MenuField` from that harness's providers or an Ollama endpoint); version pin; role default; hardening; cap.
- **New council**: name, hue, purpose, seats with roles, quorum, rounds, verdict rule, caps, residency, prompt.
- **New route**: caller (any harness, or a named agent identity), target (a seat or a council), limits.

A sheet:
- Validates on Save and shows `ProblemText` per field.
- Saves through the config store, which re-reads first.
- Never closes on a failed save.

## Visual layer: "the council thinks"

The panel keeps the house shell; inside it, deliberation is drawn as a small nervous system. Rules first,
because Bton's perpetual pulse once made its panel lag:

- **Event-driven bursts, not loops.**
  - An animation starts because something happened (a seat started, a claim landed, a rebuttal, a verdict) and ends within 1.2 s.
  - Between events the scene is static.
  - The only continuous motion is a slow breath (4 s period) on live nodes. It is a Core Animation layer animation (GPU, no SwiftUI invalidation) and runs only while a sitting or thread is live.
- **Core Animation, not SwiftUI.**
  - The scenes are `NSViewRepresentable` views hosting `CAShapeLayer`, `CAGradientLayer` and `CAReplicatorLayer`.
  - SwiftUI animation APIs are banned in `Views/` (the Motion guard); they live in `Kit/Synapse/` and `Kit/Motion.swift`.
  - `TimelineView` may run inside `Kit/Synapse/` only for the length of a burst.
- **Pause and reduce.**
  - Panel scenes stop when the panel is hidden or occluded (`panelVisible`).
  - The menu bar icon is always visible, so it has its own rules:
    - It animates only while something is live, at 8 fps.
    - It stops while the screen is asleep or locked.
    - With Reduce Motion it shows a static live badge instead.
  - Reduce Motion replaces travel and growth in the panel with 0.2 s cross-fades.
  - `stillImage` draws the final frame for renders.
- **Budget**, measured by `scripts/perf.sh` (MacMax's, extended):
  - **Method**: a release build on the reference Mac (the owner's Apple silicon Mac; the model is recorded in the output).
  - Sampling: 30 s warm-up, then `ps -o %cpu= -p <pid>` once a second for 60 s. The app process and its WindowServer share are reported separately, and the budget applies to the app process.
  - Workload: a stub broker feeding the scenario; the live case is a 5-seat stub sitting emitting one claim every 5 s.
  - The script fails when the mean exceeds the budget.

  Core Animation keeps work off the main thread but does not by itself prove low CPU; the measurement does.

  | Situation | Average CPU over 60 s |
  |-----------|-----------------------|
  | Panel closed, nothing live | under 0.3% |
  | Panel open, nothing live | under 1% |
  | Panel open, one live sitting, a claim every 5 s | under 6% |
  | Menu bar animating, panel closed | under 1.5% |

### Scenes (all in `Kit/Synapse/`)

1. **Council ring** (bento big tile, sitting expansion):
   - Seats are nodes on a ring, each with its vendor mark; the verdict core sits in the center.
   - A thinking seat breathes in `accent`.
   - When a claim lands, a spark travels from the seat to the core along a curved synapse, using a path `strokeEnd` from 0 to 1 over 0.6 s, `snappy`.
   - A rebuttal draws a chord between two seats in `warn`.
   - Agreement thickens the chord in `ok`.
   - On the verdict, every chord retracts into the core over 0.8 s, `gentle`, and the core fills with the verdict hue and one ring ripple. The minority seat keeps a thin `accent2` thread to the core, so the dissent stays visible.
2. **Claim timeline** (sitting expansion): lanes per round (Blind, Rebuttal, Challenge, Verdict).
   - Claims are dots that rise in.
   - A rebuttal draws an arc back to the claim it answers.
   - Dropped claims fade to `textTertiary` with a strike; the minority claim keeps its `accent2` ring.
   - It is static once the sitting ends.
3. **Thread pulse** (Threads rows): a two-node line, caller to seat.
   - A pulse runs out when the question leaves and back when the answer arrives.
   - Follow-ups add a tick on the line.
4. **Menu bar synapse** (new work on Bton's `MenuBarIcon` plumbing, 22x22, 8 fps):
   - While live: a 14-frame cycle where the glyph's nodes light in turn, then a 3.25 s rest on the template frame (a burst, not a loop; drawing a status item image costs about 3 ms a frame, so a continuous 8 fps loop measured 2.6% against the 1.5% budget).
   - A verdict: one flash in the verdict hue, then back to the template.
   - Frames are pre-rendered once per look, never drawn per tick.
5. **Seat calibration bars** (Seats rows): animate only when a new outcome changes the number, never on appear.
6. **Backdrop texture** (look `agencil` only): a static low-contrast neural mesh image at 4% opacity behind the glows, rendered once at build time from `Brand/mesh.svg`. Never animated.

## Screenshots and demo data

- `Agencil --render-screenshots <dir> [--all-looks] [--stress] [--scale N]` renders every tab, every pane and every sheet, in every look, from `DemoStore`, at 2x by default, using MacMax's renderer.
- Demo data is synthetic:
  - Repos: `harbor/checkout`, `lumen/api`, `orbit/web`.
  - People: maya, jonas, lee.
  - Seats: the real vendor names (identification is fine) with made-up model versions.
- Renders prove layout only. A UI change is done when the installed build was looked at live; otherwise the report says "UI not exercised live".

## Enforcement

Every guard below is a test in `Tests/AgencilTests/` (or `scripts/check.sh` for text lints). Codex writes
them in U2 from this section, before the kit is built, each with adversarial fixtures that try to slip past
it.

The guards work by allowlist, not by listing bad patterns: outside `Kit/`, a view may use only kit
components, tokens and plain layout. That makes moving code a few lines away or into a helper useless as a
bypass. The source is split into:
- `Sources/Agencil/Kit/` (the kit);
- `Sources/Agencil/Views/` (screens: compose kit pieces only);
- `Sources/Agencil/Store/` (the `@MainActor @Observable` store and its async work).

The scan strips comments and string literals first, then matches tokens.

| Guard | Rule for `Views/` | Allowed in |
|-------|-------------------|------------|
| Press | No `Task`, `Task.detached`, `DispatchQueue`, `async let` or `await` at all; views call store methods through `AsyncPress` only. `inFlight.perform(` appears exactly once | `Kit/AsyncPress.swift`; `Store/` may use `Task` |
| Buttons | No `Button(`, `.onTapGesture`, `.gesture(`; only kit buttons and `HoverCard(action:)` | `Kit/` |
| Font | No `.font(` except `.font(.house.<token>)`; no `Font.` or `.system(` in any form | `Kit/Tokens.swift` |
| Size and spacing | No numeric literal at all in `Views/` except `0`, `1`, array indexes and `Double` opacities from `Theme.opacity` tokens; frames, paddings, spacings, offsets and radii take `Size.`, `Space.` or `Radius.` tokens | `Kit/` |
| Color | No `Color`, `NSColor`, `.white`, `.black`, `.primary`, `.secondary` or any named system color; colors are `Theme.<token>` or `Theme.color(for:)` only | `Kit/Looks.swift`, `Kit/Theme.swift` |
| Native controls | No `Toggle`, `Picker`, `Menu`, `Stepper`, `Slider`, `TextField`, `SecureField`, `.alert`, `.confirmationDialog`, `.popover`, `.sheet` | `Kit/` |
| Scheme | No `.preferredColorScheme` or `.environment(\.colorScheme` | `Kit/HouseScheme.swift` |
| Motion | No `.animation(`, `withAnimation`, `.repeatForever` or `TimelineView`; transitions use kit modifiers (`.riseIn`, `.houseTransition`) | `Kit/Synapse/`, `Kit/Motion.swift`, and `Kit/RelativeTime.swift` (a minute clock, paused when the panel is hidden) |
| Sheet | `.houseSheet(item:)` is the only presenter; it wraps content in `ModalFrame` itself | `Kit/HouseSheet.swift` |
| Kit purity | `Kit/` imports only SwiftUI, AppKit, QuartzCore and Foundation, and names no type from `Views/` or `Store/` | |

A screen that seems to need a literal or a native control is the signal to add a kit component, never to
widen a guard's allowlist.

Layout tests (RMJ `PanelLayoutTests`, rendered offscreen):
- The panel is exactly 404 pt wide in every tab and look.
- Every control in a row measures `Size.control` (28) tall, within 0.5 pt.
- The longest synthetic names fit: a 48-character repo, a 60-character model id, a 120-character reason.
- Every empty and waiting state renders in every look.
- Every Settings pane and sheet renders at the minimum window size without horizontal scroll.

`scripts/check.sh` also:
- Fails on files over 500 lines.
- Fails on non-ASCII punctuation in Sources, docs and README.
- Fails on a demo fixture containing a name from `scripts/forbidden-names.txt`. That file is git-ignored and lists the owner's client names; it is absent in CI, which then checks nothing.

A guard is never skipped or loosened to land a change. If the kit cannot express a design, the kit grows
first, in its own commit, with this file updated.
