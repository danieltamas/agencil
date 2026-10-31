# U15b contract: `wake` seat and cap overrides

Part of the council cutover (docs/U15-SPEC.md, blockers 1 and 2). Two optional fields narrow one sitting; neither widens anything.

- CLI: `agencil wake <council> --brief F [--seats a,b,c] [--cap <seconds>]`. MCP `wake_council` is unchanged.
- Broker `wake` request fields: `seats` (list of seat names) and `cap_seconds` (whole number).
- `seats`: the sitting convenes only these seats, in the council's own order. Every name must be a seat of that council (spares and
  synthesizers are not affected); an empty list, a duplicate or a name outside the council is refused with exit 64
  `usage: seats must be seats of the council` and nothing is opened. The council's quorum and verdict rules still apply to the
  smaller panel (a quorum above the remaining seat count gives an `INCOMPLETE` verdict, never a pass).
- `cap_seconds`: a whole number from 1 to 86400, else exit 64 `usage: cap must be a whole number of seconds`. Each seat's cap for this
  sitting is the smaller of its configured cap and this value (an override can only shorten a call). The sitting's deadline is unchanged.
- The overrides are recorded in the sitting's brief text as `seats:` and `cap:` lines so the ledger shows what was convened.
- CLI parsing: `--seats` and `--cap` are valued flags of `wake` only; a non-numeric `--cap` or an empty `--seats` exits 64.

## Acceptance
- A 3-seat council woken with `seats: [two of them]` runs exactly those two (stub seats record their calls) and the verdict votes list those two.
- A name outside the council, a duplicate and an empty list exit 64 with no sitting opened and no seat started.
- `cap_seconds: 5` gives every stub seat a cap of at most 5 (seen in the seat's launch deadline or environment as the existing tests observe caps); a seat configured with 3 keeps 3.
- `cap_seconds` 0, 86401 and 2.5 exit 64.
- Without the fields nothing changes (the existing U7 suites keep passing).
