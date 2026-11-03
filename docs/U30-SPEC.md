# U30: follow-up questions on a finished sitting

After a council has sat, the owner can keep the discussion going: ask one of its seats a follow-up from the sitting's detail
page, read the answer there, and ask again. The seat is given the sitting's record (the question, the synthesis, the seats'
final answers and claims) as evidence, so the follow-up needs no re-explaining. Every answer and its cost is kept.

## Behaviour: broker

1. **`followup` op.** `{"op":"followup","caller":"owner","sitting":"sit_...","question":"...","seat":"<name>"?}`. Only the
   panel's own process may send it (the same test as the owner's wake exemption, `isAppPeer`: wire `caller` is a claim); any
   other caller, `as`, or a seat's child is refused `refused: a follow-up comes from the panel` (exit 3). Exit 64 for a
   missing or non-string `sitting` or `question`, a blank question, a question over 8,000 characters, a `seat` that is not a
   string, an id that does not start `sit_`. Exit 4 `failed: unknown sitting` for an unknown id; `failed: the sitting is still
   running` while its state is `running`; `failed: <seat> is not a seat of council <name>` for a seat outside the council's
   seats, spares and synthesizers as configured now; `failed: no council named <name>` when the council was removed.
2. **Which seat.** `seat` when given; else the seat that wrote the synthesis (`summary_by`); else the first seat that answered
   in the council's order; else the council's first seat.
3. **A thread per seat per sitting.** The first follow-up to a seat opens a thread linked to the sitting (`thread_rounds`
   with round `followup`); its first question is the owner's text inside the evidence packet below. Later follow-ups to the
   same seat of the same sitting continue that thread (the seat sees the earlier exchanges as a transcript) with just the
   owner's text. At most one exchange per thread is open: a follow-up while the previous one is still asking fails
   `failed: <seat> is still answering the last follow-up` (exit 4) and starts nothing.
4. **The evidence packet** (first exchange of a thread), every part labelled as evidence, never as instructions, in this
   order: `FOLLOW-UP ON SITTING <id>`; `QUESTION OF THE SITTING:` the original question; `SYNTHESIS:` the summary when there is
   one; `FINAL ANSWERS OF THE SEATS:` one `[seat <name>]` paragraph per seat from the last round that seat answered, notes
   and claim evidence flattened to one line and cut at 4,000 characters each; `VERDICT:` the verdict word and reasons;
   `OWNER'S FOLLOW-UP:` the owner's text; and the last line `Answer in Markdown prose for the owner. Do not answer in JSON.`
   A later question on the same thread is stored and sent as the owner's text alone (the transcript holds the packet)
   The packet is cut so it never exceeds 48,000 characters (the seat answers are cut first, longest first).
5. **How it runs.** Like a sitting's seat run: the seat is resolved and admitted (budgets, capacity, residency, policy),
   launched with the packet verbatim, with no repo and no tools beyond the seat's usual sandbox, and runs on the implicit
   route `owner -> <council>` with hop limit 1. The reply returns at once:
   `{"ok":true,"data":{"sitting":"sit_...","thread":"th_...","seat":"...","seq":<n>}}`; the answer is read through `detail`.
6. **`detail` for a sitting** returns `followups`: one entry per follow-up thread of the sitting, ordered by creation:
   `{"seat","thread","model","harness","exchanges":[{"seq","question","answer"?,"state","reason"?,"tokens"?,"tokens_in"?,
   "tokens_out"?,"cost_usd"?,"cost_note"?}]}`. `question` is the owner's own text (never the packet; for the first
   exchange the text after `OWNER'S FOLLOW-UP:` and before the closing instruction line). The `followup` threads are no
   longer listed as a round in `rounds`. It also returns `follow_up_seats` (the seats the owner may pick, in council order:
   seats, then spares, then synthesizers, each once, only configured seats) and `follow_up_default` (the seat item 2 picks).
7. A follow-up thread appears in the panel's Threads list like any thread, shown by the owner's own question; its cost is in
   the Costs pane (U31) with the sitting's other seat runs.

## Behaviour: panel

8. A sitting's detail page whose state is not `running` ends with a `Follow up` block: the follow-ups so far (per seat, in
   order, each turn as the owner's question then the seat's answer drawn with `MarkdownBlock`, with the answer's model, time
   and cost line), then a composer: a seat picker (a row of `SegmentChip` for up to 3 seats, a `MenuField` for more (the panel is 404 pt wide); the
   default is `follow_up_default`), a `GlassEditor` for the question, and an `Ask` `PillButton` through `AsyncPress`
   (disabled for a blank question; a second press while it runs sends one request). A running sitting shows no composer.
9. Pressing Ask sends one `followup` as `owner`; on success the field clears and the new turn shows `Thinking...` until its
   answer arrives (the page refreshes while any follow-up is asking); on a refusal the text stays and the refusal is shown
   in the problem line. The picked seat and the unsent text survive a refresh of the page.
10. The page follows `docs/DESIGN.md` and the kit; the guard tests stay green. No new control outside `Kit/`.

## Interfaces (fixed so tests can be written before the code)

- Broker op name `followup`; `Broker.followupOp(_ request: [String: Any], peer: Int32?, peerStart: Double?) -> [String: Any]`
  (dispatched from the op switch like `wake`). Test seams are the same as U27: `AGENCIL_TEST_SEAMS=1` and
  `AGENCIL_TEST_APP_PEER=<pid>` make that pid the panel.
- `SittingDetail` gains `followups: [Followup]`, `followUpSeats: [String]`, `followUpDefault: String?`;
  `struct Followup: Sendable, Equatable { let seat: String; let thread: String; let model: String?; let harness: String?;
  let exchanges: [ThreadDetail.Exchange] }`.
- `DetailPage` gains `var followups: [Followup]` (`struct Followup: Equatable, Identifiable { let seat: String; let vendor: String;
  let turns: [Turn] }`, `struct Turn: Equatable { let question: String; let answer: String; let meta: String; let tone: Signal }`),
  `var followUpSeats: [String]`, `var followUpDefault: String?`, `var canFollowUp: Bool`
  (true once the sitting's state is not `running`, detail has loaded, and there is at least one seat to pick). `live` is also
  true while any follow-up exchange is `asking`.
- `PanelStore`: `var followUp: FollowUpDraft?` (`struct FollowUpDraft: Equatable { var seat: String; var text: String }`),
  `var followUpProblem: String?`, `var canSendFollowUp: Bool`, `func sendFollowUp() async`,
  `func sendFollowUpAction() -> () async -> Void`. The draft is kept per sitting id across refreshes and cleared on success.

## Acceptance

A1. `followup` from the panel peer on a finished sitting, no route configured: starts a thread linked to the sitting; the reply
    has `thread`, `seat`, `seq` 1; the seat's prompt starts with `FOLLOW-UP ON SITTING <id>` and contains, in order, the
    sitting's question, the synthesis text, each seat's last answer, the verdict, and `OWNER'S FOLLOW-UP:` + the text, and ends
    with the Markdown instruction. A seat marker planted in a claim's evidence appears on one line.
A2. The same call from any other process (caller `owner`, no seam), with `as`, or as a seat's child is refused exit 3 and
    starts nothing.
A3. Usage and state refusals of item 1 each give their exit code and message, start no seat, and write no thread.
A4. Seat choice of item 2: explicit seat; `summary_by`; first answered; council's first (one case each).
A5. A second follow-up to the same seat continues the thread: the seat's prompt carries the first exchange as a transcript and
    the new text, not the packet again. A follow-up to another seat opens a second thread. A follow-up while the first is still
    asking is refused exit 4 and the thread has one exchange.
A6. `detail` of that sitting: `followups` with the owner's question (never the packet), answer, state, tokens and cost
    fields as for threads; `rounds` has no `followup` round; `follow_up_seats` and `follow_up_default` as item 6.
A7. A follow-up seat run is charged to the budgets like a sitting seat run: a vendor budget already spent refuses it with the
    budget refusal and starts nothing.
A8. A packet whose parts exceed 48,000 characters is cut to at most that, seat answers first; the owner's text is never cut.
A9. `DetailPage.sitting` with a `SittingDetail` that has followups: `followups` turns with question, answer text and meta line;
    `canFollowUp` false for a running sitting, before the detail loads, and with no seats; `live` true while a follow-up is
    asking; `followUpDefault` and `followUpSeats` carried over.
A10. Panel store: `sendFollowUp` sends one `followup` as `owner` with the sitting, the picked seat and the trimmed text; a
     double call while it runs sends one request; success clears the text, keeps the seat and refreshes the detail; a refusal
     keeps the text and sets `followUpProblem` to the refusal text; the draft survives a detail refresh; blank text disables.
A11. Layout: the sitting page with 6 follow-up turns of long Markdown answers, an 8-seat picker and a long draft fits the panel
     width with no horizontal scroll in every look (a `PanelLayoutTests` case).
A12. Existing behaviour: a sitting with no follow-ups returns `followups: []` and its rounds are as before; threads from before
     this unit show unchanged.

## Amendment: the council, not a seat (owner feedback after the first live use)

- The panel asks the **council that held the sitting**, not one seat: the follow-up request is `{sitting, question, council: true}`
  (`council` must be `true` and excludes `seat`; anything else is exit 64). The broker asks every seat of the council, each on its
  own thread exactly as a single-seat follow-up (same gate, packet, budget, overlap rules). The reply is the first started seat's
  `{sitting, thread, seat, seq}` plus `threads[]` (each started seat's `{sitting, thread, seat, seq}`) and `skipped[]`
  (`{seat, reason}` for a seat that could not be asked: still answering, over budget, not installed). It fails only when no seat
  could be asked, with the first seat's refusal. Single-seat `{seat}` requests keep working unchanged (CLI, tests).
- The panel has no seat picker. The composer is a box pinned to the bottom of the sitting's page, outside the scrolling content,
  titled "Ask the council"; the threads of the answers stay in the scroll under "Follow up".
- A9 (new): a `council: true` request on a finished 2-seat council starts one thread per seat (both prompts start with
  `FOLLOW-UP ON SITTING <id>`), returns `threads` with both and an empty `skipped`; when one seat is still answering its last
  follow-up, that seat is in `skipped` with the "still answering" reason and the other still starts; `council: false`, or
  `council: true` with `seat`, is exit 64 and starts nothing. The page store sends `council: true` and no `seat`.

## Amendment 2: size, floating Ask, attachments

- The box is `Size.followUpEditor` (112 pt) high and never grows; Ask floats inside its bottom-trailing corner at `Space.float` (10 pt).
- Cmd-V in the box takes the clipboard's images (saved as owner-private PNGs, like the New sitting form) and copied files, several at once,
  at most 8; each shows as an `AttachmentTile` (the picture for an image, a document glyph and name for a file) with a remove control.
- The request gains `files: [absolute paths]` (images and text files, read once by the broker with the wake's rules: images up to 10 MB each,
  20 MB in all; exit 64 on a bad path). Every asked seat gets the text files as evidence and the images the way a wake delivers them.
  After a successful send the pasted files are deleted and the tiles clear.
