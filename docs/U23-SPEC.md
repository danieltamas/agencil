# U23 - the reviewing seat

U12 requires a different-vendor seat to review a proposal before approval, and U22 left nothing that runs that seat.
This unit adds `learn review`, an owner action that asks the reviewer through the ordinary ask path and records the
verdict. Nothing reviews on its own: the review costs a seat run, so it starts only on the owner's press or command.

## Broker (Sources/AgencilCore/Broker/BrokerLearn.swift)

- `learn` takes a fourth action, `review`, with a required `id`. Owner only (`requireOwner`), config validated first.
- The reviewer is `LearnLoop.reviewer(for:)`. None -> exit 4 "no seat of another vendor can review <id>".
  An unknown or not-open proposal -> exit 4 with the `LearnError` message (U12 rules unchanged).
- The question is built by Agencil, never from seat text: the proposal kind, council, seat change or prompt
  variable and value, and the evidence JSON, each labelled as evidence, then the instruction "Reply with ENDORSE or
  OBJECT on the first line, then one short reason." It goes through `ask` as the owner (target = the reviewer seat, so
  routes, budgets, placement and caps apply, and a refusal surfaces as that refusal's message and exit).
- The wait is `request["wait_seconds"]` (default 600, at most 3600). A reply that is not `answered` -> exit 2 for
  `pending`, exit 4 for `failed`, with the thread id in the message; nothing is recorded.
- The first word of the answer (letters up to the first space, `:`, `.` or end of line), uppercased, must be `ENDORSE` or `OBJECT`;
  the rest of that line and the following lines, trimmed of leading `:` and `.`, whitespace-collapsed, control characters removed and cut to the U12 maximum note
  length, is the note. Anything else -> exit 4 "the reviewer gave no verdict", nothing recorded.
- A verdict is recorded with `LearnLoop.review(_:by:verdict:note:at:)`. Reply: `{"action":"review","id","reviewer","verdict","note"}`.
- An OBJECT verdict is recorded (the owner sees it) and does not reject the proposal.

## CLI and panel

- `agencil learn review <id> [--wait N]`. AGENT-API.md row.
- The panel proposal row shows Review for a `proposed` proposal (pending and failed attempts show the broker message as the
  panel problem line), and keeps Reject. Approve still appears only for `reviewed` + `endorse`.

## Acceptance

1. With a stub reviewer seat of another vendor answering "ENDORSE\nlooks sound", `learn review` records reviewer, verdict
   endorse and the note; `proposals` then shows status `reviewed`; `learn approve` then applies it.
2. An answer "OBJECT: breaks quorum" records verdict object; the proposal stays open (reviewed) and Approve in the panel
   model is not offered (the row's `endorsed` is false).
3. An answer with no verdict word is exit 4 and the proposal stays `proposed`.
4. No other-vendor seat -> exit 4; unknown id -> exit 4; a seat child calling review -> exit 3.
5. The question the reviewer receives contains the evidence labelled as evidence and never the text of an earlier note.
6. A reviewer that fails (stub exit non-zero) -> exit 4 and nothing recorded.
7. CLI parses `learn review <id> --wait 5`; `learn review` without an id is a usage error.
