FAIL

- 2 FIXED - docs/AGENT-API.md:71 explicitly refuses failed peer-PID lookup or ancestry traversal.
- 3 STILL OPEN - docs/AGENT-API.md:91 permits streaming-usage termination, which cannot prevent already billed input or in-flight generation from exceeding a reservation; separate input/output prices also lack a defined allocation.
- 5 STILL OPEN - docs/PLAN.md:426 allows reads throughout harness config directories without sanitizing them, leaving other sessions, history or secrets readable into provider requests.
- 9 FIXED - docs/LEADERBOARD.md:69 defines shared alias approval through main, and line 73 applies exclusions by provider/model.
- 10 STILL OPEN - docs/PLAN.md:322 restricts golden recall to valid answers while line 323 counts abstentions, and line 324 leaves zero known defects with nonzero briefs undefined.
- 12 FIXED - docs/PLAN.md:166 defines durable launch intent, registration before execution and recovery that waits for the process group to disappear.
- 13 FIXED - docs/PLAN.md:253 explicitly returns PASS when `any blocker` finds no qualifying claim.
- 17 FIXED - docs/BRAND.md:41 identifies the frame pipeline as new work.
- 18 FIXED - docs/AGENT-API.md:153 defines scalar bounds, UTF-8 truncation and paged access to full answers.
- N1 FIXED - docs/PLAN.md:267 requires tests for both `any blocker` outcomes.
- N2 FIXED - docs/PLAN.md:241 defines unknown authors and requires INCOMPLETE for high-risk councils, with acceptance cases at line 266.

New P0/P1 introduced by fixes: None beyond the remaining issues above.