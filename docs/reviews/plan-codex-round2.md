FAIL. Several safety contracts remain incomplete. This is a document review; no implementation tests were run.

1. FIXED - docs/PLAN.md:88 puts the CLI in Contents/Resources/agencil and binds signing, installation and acceptance to that path.

2. PARTIAL - docs/AGENT-API.md:65 adds capabilities and process ancestry; docs/PLAN.md:198 adds adversarial tests. Remaining: specify refusal when peer-PID lookup or ancestry traversal fails. An unreadable parent must not become a root.

3. PARTIAL - docs/AGENT-API.md:83 adds durable reservations and cumulative charging. Remaining: define enforceable per-run limits, missing-usage reconciliation and the undefined "overrun allowance" in docs/PLAN.md:207. Dollar reservations cannot guarantee hard spending caps when only time/token limits terminate execution.

4. FIXED - docs/AGENT-API.md:93 parks waiting ancestors, bounds total processes and immediately refuses impossible requests; docs/PLAN.md:204 tests concurrency one.

5. PARTIAL - docs/PLAN.md:398 defines the broader outbound boundary and scrubbing. Remaining: require confinement of filesystem reads to sanitized inputs. Read-only access and disabled network tools do not prevent a hosted harness from reading other local files into provider requests. Strip Git back-pointers, history and escaping symlinks; test those paths.

6. FIXED - docs/PLAN.md:217 specifies snapshot worktrees, captured dirty patches, snapshot-bound answers and cleanup; line 253 tests concurrent checkout changes.

7. FIXED - docs/LEADERBOARD.md:30 specifies branch, content, message and expected SHA in the PUT body.

8. FIXED - docs/LEADERBOARD.md:35 dispatches a main-branch workflow with explicit code/data checkouts and workflow serialization.

9. PARTIAL - docs/LEADERBOARD.md:67 adds public identifiers and CI validation. Remaining: reconcile owner-approved custom aliases with CI's shipped allowlist. Replace exclusion "by harness" at line 95 and docs/PLAN.md:425 with provider/model exclusion, matching line 72.

10. PARTIAL - docs/PLAN.md:299 defines deduplication, coverage and golden recall. Remaining: remove automatic correctness labels based solely on a commit surviving 14 days or being reverted (lines 296-297). These remain evidence, not adjudication. Define abstention and zero-denominator behavior for coverage and golden metrics too.

11. FIXED - docs/PLAN.md:122 adds locking, revision checks and atomic writes; docs/AGENT-API.md:186 defines create/refuse/replace and unchanged-entry uninstall behavior.

12. PARTIAL - docs/PLAN.md:164 adds lifetime locking and recovery. Remaining: line 165 requires a PID before spawning. Specify a launch handshake that records identity before model execution, including crashes between spawn and registration. Do not release reservations merely because the leader died while descendants remain.

13. PARTIAL - docs/PLAN.md:225 makes recusal absolute and adds quorum and verdict ordering. Remaining: complete the "any blocker" rule's no-blocker outcome; see N1 below.

14. FIXED - docs/DESIGN.md:342 replaces proximity checks with folder/token restrictions; docs/PLAN.md:103 requires adversarial fixtures. docs/DESIGN.md:360 explicitly permits the paused minute clock.

15. FIXED - docs/DESIGN.md:29 removes the AppStore dependency through kit-owned action state; line 361 requires the kit-owned sheet presenter.

16. FIXED - docs/PLAN.md:55 makes U2 depend on U3 and explicitly places U3 first.

17. PARTIAL - docs/DESIGN.md:30 and line 320 identify continuous animation as new work; line 280 separates panel/icon visibility and line 288 defines measurement. Remaining: correct docs/BRAND.md:39, which still attributes the proposed frame pipeline to Bton.

18. PARTIAL - docs/AGENT-API.md:140 corrects schema placement and versioned result handling. Remaining: define bounded scalar fields and oversized-answer behavior. Line 145's list-only truncation cannot bound a single large answer, evidence string or error message.

19. FIXED - docs/AGENT-API.md:54 distinguishes OpenCode permissions from isolation and requires a verified adapter policy or refusal.

20. FIXED - docs/PLAN.md:36 names mandatory live scenarios; line 113 defines clipping assertions; line 305 defines probation thresholds; line 350 requires compatibility fixtures; line 90 distinguishes signing reproducibility modes.

NEW P0/P1 problems introduced:

- N1 - P1, docs/PLAN.md:239: The new truth table has no verdict when rule "any blocker" finds no qualifying blocker. Neither following row applies to that rule. Add an explicit no-blocker result after the completeness checks and test both branches.

- N2 - P1, docs/PLAN.md:228: Absolute recusal now falls back to the caller's harness vendor when author_vendor is absent, but CLI and scheduled callers need not have one. Define an explicit unknown-author state that refuses independent-review certification or returns INCOMPLETE, and test missing and unrecognized author identities.