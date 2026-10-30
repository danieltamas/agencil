FAIL. The plan has build blockers and incomplete safety contracts.

1. **P0 - docs/PLAN.md:77: The bundle layout overwrites the app executable.** `Contents/MacOS/Agencil` and `Contents/MacOS/agencil` are the same filename on default macOS filesystems. MacMax explicitly avoids this in `scripts/bundle.sh:52`. **Fix:** put the CLI at `Contents/Resources/agencil`; update bundling, signing, installation and acceptance paths together.

2. **P0 - docs/AGENT-API.md:61: Chain ancestry is optional in practice.** Environment inheritance is harness-specific; a missing parent becomes a new root, resetting depth and cycle tracking. `no-chain` removes MCP but leaves the CLI/socket reachable. Same-user spoofing is acknowledged, but accidental ancestry loss remains. **Fix:** use broker-issued per-run capabilities bound to seat and ancestry, explicit MCP forwarding, and tests for stripped, replaced and replayed parents plus CLI recursion. Qualify guarantees against deliberately malicious same-user code. [Codex forwarding configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

3. **P1 - docs/AGENT-API.md:47: Budget checks do not define enforceable spending limits.** One broker prevents duplicate ownership, not overspending by running processes. Unknown cost, retries, fallbacks, rounds and restart recovery are unspecified. **Fix:** define durable atomic reservations, reconciliation and cumulative chain charging; reject unknown pricing for hard dollar caps and distinguish estimated from provider-enforced caps.

4. **P1 - docs/AGENT-API.md:48: Nested calls can deadlock.** At concurrency one, A holds the slot while waiting for B, which queues behind A. **Fix:** define whether suspended ancestors consume capacity, reserve chain capacity or reject impossible chains immediately. Add concurrency-one and exhausted-capacity acceptance cases.

5. **P1 - docs/PLAN.md:307: Brief scrubbing does not contain egress.** A hosted harness can read additional repository files or use its own network tools after the brief is scrubbed. Rebuttals, transcripts, outputs and logged argv are uncovered. **Fix:** define the entire outbound packet and storage redaction boundary; use sanitized snapshots and enforced tool/network restrictions. Recheck residency and disclosure policy after fallback resolution.

6. **P1 - docs/PLAN.md:166: A hash does not freeze what seats read.** Seats launched in a changing checkout can inspect different code despite identical packet metadata. **Fix:** run against an immutable snapshot or detached worktree; define dirty-file handling and bind every answer, round and verdict to that snapshot.

7. **P1 - docs/LEADERBOARD.md:30: The Contents API write targets the wrong branch.** PUT takes `branch` in the body; `?ref=leaderboard` is GET syntax. The default branch may be modified or the request may fail on SHA mismatch. **Fix:** send `branch`, base64 `content`, `message` and the expected blob `sha` explicitly. [API contract](https://docs.github.com/en/rest/repos/contents)

8. **P1 - docs/LEADERBOARD.md:8,32: The orphan branch cannot run the described push workflow.** Its listed files contain neither workflow nor renderer. **Fix:** bootstrap a workflow on that branch and explicitly fetch trusted renderer code, or dispatch a main-branch workflow after publication. Specify nightly checkout refs and serialize publishers/renderers. `GITHUB_TOKEN` commits will not trigger another push workflow. [Trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)

9. **P1 - docs/LEADERBOARD.md:55: The privacy allowlist accepts private model labels.** A model named `client-project` passes the regex; aggregate selection does not make that value public-safe. **Fix:** export separately approved public model identifiers, reject unknown identifiers, and apply provider restrictions by provider/model rather than harness.

10. **P1 - docs/PLAN.md:219: Recall has no defined denominator.** Finding dispositions reveal reported positives, not missed defects. A commit mentioning an ID also does not prove correctness. **Fix:** define adjudicated outcomes, deduplication, false negatives, reverts, abstentions and zero denominators. Publish recall only on fully labeled evaluation sets; classify commit references as evidence pending adjudication.

11. **P1 - docs/PLAN.md:104,311: Re-reading before writing is still a race.** Two writers can read the same version and overwrite each other. Uninstall can delete a pre-existing entry, contradicting byte-identical restoration. **Fix:** require locking or revision CAS, atomic replacement, ownership/symlink checks, and explicit create/replace/refuse behavior. Restore overwritten entries only when unchanged since installation.

12. **P1 - docs/PLAN.md:137: Broker crash recovery is missing.** Socket permissions and live-instance rejection do not cover stale sockets, launch races or children surviving broker exit. **Fix:** specify an atomic lifetime lock, safe stale-socket removal, durable launch intent, startup reconciliation and reservation retention until process death is proven.

13. **P1 - docs/PLAN.md:170: Voting and independence are underspecified.** Recusal is absolute here but tolerated with a flag at line 179. Quorum defaults, majority denominator, synthesizer failure and blocker precedence are undefined. **Fix:** provide a verdict truth table, minimum independent participation and exact failure outcomes; reconcile recusal wording before acceptance tests are written.

14. **P1 - docs/DESIGN.md:329: The guards do not enforce the promised standard.** Moving `Task` six lines away or into a helper bypasses Press; font overloads, `.white`, alternate color constructors and numeric frames bypass other guards. Conversely, copied `RelativeTime` uses a forbidden `TimelineView`. **Fix:** enumerate permitted APIs with syntax-aware checks and adversarial fixtures; explicitly permit a paused minute clock or replace it.

15. **P1 - docs/DESIGN.md:337: The Sheet guard has no implementable contract.** Generic sheet content may wrap `ModalFrame` in modifiers or another view; a text scan cannot prove its type. The kit also forbids app model dependencies while copied `AsyncPress` directly depends on `AppStore`. **Fix:** expose one kit-owned sheet presenter and inject an app-independent action-state interface. Test registered sheet routes through that presenter.

16. **P2 - docs/PLAN.md:47,99: U2 requires U3 before U3 exists.** Persisting the look needs `ConfigStore`; the dependency table says U2 depends only on U0. **Fix:** make U2 depend on U3, or move persistence acceptance into the integration unit.

17. **P2 - docs/DESIGN.md:30,305; docs/BRAND.md:39: Bton's animation is misrepresented.** Its current `MenuBarIcon` draws a static working icon and a short 14-frame sync ripple, not continuous pre-rendered frames. "Everything stops" when hidden also contradicts the menu-bar budget. **Fix:** label continuous animation as new work, separate panel/icon visibility, and define reference hardware, CPU accounting, warm-up and workload. Core Animation alone does not establish low CPU.

18. **P2 - docs/AGENT-API.md:116: MCP schemas are misplaced and incomplete.** `outputSchema` belongs to tool definitions; structured results use `structuredContent`. The verdict table is not a machine-checkable schema. **Fix:** provide version-specific tool/result schemas, valid bounded truncation, initialization behavior and error envelopes. [MCP tool contract](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)

19. **P2 - docs/AGENT-API.md:54: OpenCode's permission guard is called a sandbox.** External-directory approval is not OS isolation. **Fix:** document its actual permission behavior and add a tested read-only adapter policy or refuse unsupported safety modes. [OpenCode permissions](https://opencode.ai/docs/permissions/)

20. **P2 - docs/PLAN.md:36,96,225,260: Acceptance can pass without proving completion.** Live smoke may skip required harnesses; "names fit" lacks clipping criteria; probation references an undefined score/floor; cutover relies on unspecified old-script behavior. **Fix:** require named live scenarios, explicit layout assertions, scoring formulas and captured compatibility fixtures. Also pin signing mode and reproducibility expectations: MacMax verifies byte identity for its ad hoc archive, not its certificate-signed archive.

Verified correct:

- Installed CLI help supports the listed Codex hardening flags, `claude -p` and `opencode run`.
- MacMax has the 196-point Settings sidebar, 760 x 540 minimum, and offscreen `NSHostingView`/`cacheDisplay` renderer.
- Bton has fixed-height `FieldCapsule` and 25-item `RowStack`; its current field height is 30, so 28 requires adaptation.
- Registry icon limits, release ping/poll and release-before-registration sequence match its producer contract.
- GitHub supports the proposed README `picture` mechanism. [GitHub documentation](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/quickstart-for-writing-on-github)

Cut from 0.1.0: **U12's automatic learn-loop proposals.** Keep outcome collection and manual council configuration until the scoring contract and evidence are reliable.