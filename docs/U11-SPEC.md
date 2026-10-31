# U11 contract: outcomes and scoring

`docs/PLAN.md` U11 owns the rules. This file fixes the testable surface in `AgencilCore`
(`Sources/AgencilCore/Outcomes/`). Everything is public; tests use `@testable import AgencilCore` and
`Ledger(directory:)`. Dates are injected (`at:` / `now:`), never read from the clock inside a rule.

## Evidence (git and PR), never a label

```swift
public enum CommitEvidenceParser {
    /// Every `AG-<sitting>-<k>` id named in the text, in order of appearance, unique. Matches whole ids only
    /// (`AG-41-3` yes, `XAG-41-3` and `AG-41` no); any verb or none.
    public static func claimIDs(in text: String) -> [String]
    /// The 40-hex sha of a `This reverts commit <sha>` line, or nil.
    public static func revertedSHA(in body: String) -> String?
}

public struct EvidenceRecord: Equatable, Sendable { public let claim: String; public let source: String; public let detail: String }

public final class OutcomeBook: @unchecked Sendable {
    public init(ledger: Ledger)
    /// A commit. Ids named in `body` get `fix-commit` evidence (detail = sha). When `body` has a revert line and
    /// `revertedBody` (the body of the reverted commit) is given, the ids of `revertedBody` get `revert` evidence
    /// (detail = sha) instead. Unknown ids are skipped. Idempotent per (claim, source, sha). Returns the claim ids
    /// that received evidence. Writes no outcome row.
    @discardableResult public func recordCommit(sha: String, body: String, revertedBody: String?, at: Date) throws -> [String]
    /// A PR dismissal comment naming claim ids: `pr-dismissal` evidence, detail = the comment url. No outcome row.
    @discardableResult public func recordPRDismissal(url: String, body: String, at: Date) throws -> [String]
    public func evidence(claim: String) throws -> [EvidenceRecord]
}
```

## Adjudication and the owner

```swift
public enum AdjudicationAnswer: String, Sendable { case confirmed, refuted, cannotTell = "cannot tell" }
public enum FindingStatus: Equatable, Sendable { case pending, confirmed, refuted, unresolved }
public enum OwnerDisposition: Sendable { case confirm, dismiss }

extension OutcomeBook {
    /// The seat that may adjudicate `claim`: the first of `seats` (in order) whose vendor differs from the
    /// vendor of the seat that raised the claim and from `synthesizerVendor`. The raiser is found through the
    /// claim's seat run and its vendor through `seats` (an unknown raiser throws: fail closed). nil when none qualifies.
    public func adjudicator(for claim: String, seats: [Seat], synthesizerVendor: String) throws -> Seat?
    /// Records the adjudicator's answer. Throws when `by` shares a vendor with the raiser or the synthesizer,
    /// when the claim has no evidence, or when the owner already decided. `confirmed`/`refuted` write an outcome
    /// row (source `adjudication`, adjudicator = `by.name`, label, certainty, detail = reason). `cannotTell`
    /// writes an outcome row with label `cannot-tell` that does not change the status (it is an event).
    public func adjudicate(claim: String, answer: AdjudicationAnswer, by: Seat, seats: [Seat], synthesizerVendor: String,
                           certainty: String, reason: String, at: Date) throws
    /// The owner's final word. Writes an outcome row (source `owner`, certainty `final`, label confirmed for
    /// `confirm`, refuted for `dismiss`) that supersedes the claim's latest outcome. Works with or without
    /// evidence, and again later (the latest owner row wins).
    public func dispose(claim: String, as: OwnerDisposition, reason: String?, at: Date) throws
    /// Latest owner label if any, else the latest adjudication label, else (no label and the last event is 30 days
    /// or older at `now`) `unresolved`, else `pending`. Evidence alone (fix-commit, revert, pr-dismissal) never
    /// yields confirmed or refuted. Last event = the latest of the claim, its evidence and its outcome rows.
    public func status(of claim: String, now: Date) throws -> FindingStatus
}
```

## Findings (duplicates)

```swift
public struct ClaimRow: Equatable, Sendable {
    public init(id: String, sitting: String, seat: String, kind: String?, file: String?, line: Int?)
}
public struct Finding: Equatable, Sendable {
    public let id: String          // the lowest claim id, compared as the plain strings
    public let claimIDs: [String]  // sorted
    public let seats: [String]     // sorted, each seat once
}
public enum FindingGrouper {
    /// Claims of ONE sitting join a finding when the synthesizer linked them (`links`, each a set of claim ids)
    /// or they share kind (both non-nil, equal) and file (both non-nil, equal) and their lines (both non-nil)
    /// differ by at most 3. Joins are transitive. Claims of different sittings never join. Input order is irrelevant.
    public static func group(_ claims: [ClaimRow], links: [[String]]) -> [Finding]
}
```

## Statistics

```swift
public enum Wilson {
    /// Wilson score interval, z = 1.96. nil when `total` is 0. Bounds clamped to [0, 1].
    public static func interval(successes: Int, total: Int) -> (lower: Double, upper: Double)?
}
public struct Share: Equatable, Sendable {
    public let numerator: Int; public let denominator: Int
    public init(_ numerator: Int, of denominator: Int)
    public var value: Double?                              // nil when denominator is 0
    public var interval: (lower: Double, upper: Double)?   // Wilson; nil when denominator is 0
    public var display: String                             // "n=0" when denominator is 0, else "67%" (rounded, no decimals)
}
```
`Share` equality compares numerator and denominator only.

## Scoreboard

```swift
public struct SeatScore: Equatable, Sendable {      // one cell: a seat in a council type
    public let seat: String; public let council: String
    public let confirmedShare: Share    // confirmed / (confirmed + refuted) over findings credited to the seat
    public let coverage: Share          // of confirmed findings in sittings where the seat gave a valid answer, those it raised
    public let participation: Share     // sittings with a valid answer / sittings the seat was seated in
    public let costPerConfirmed: Double?   // sum cost_usd of the cell's seat runs / confirmed findings; nil when 0 confirmed
    public let medianSeconds: Double?      // median of ended_at - started_at over the cell's seat runs; nil when none
}
// There is no `recall` property or JSON key outside GoldenScore.

extension OutcomeBook {
    /// Every (seat, council) cell. "Change kind" is the council type until path classification exists.
    /// A valid answer = a seat run in the sitting with exit_code 0. Findings come from FindingGrouper over all
    /// claims (links empty). unresolved and pending findings count in neither numerator nor denominator of any
    /// share. Sorted by council then seat.
    public func scoreboard(now: Date) throws -> [SeatScore]
    /// Confirmed findings both seats raised / confirmed findings either raised, within one council; nil when 0.
    public func overlap(_ a: String, _ b: String, council: String, now: Date) throws -> Double?
}
```
Performance: `scoreboard` on a ledger of 10 000 claims and 100 000 assessments runs in under 50 ms (migration
adds indexes on `claims(seat_run_id)`, `claims(run_id)`, `assessments(claim_id)`, `outcomes(claim_id)`,
`evidence(claim_id)`, `seat_runs(run_id)`).

## Golden set, probation, voting-seat gate

```swift
public struct GoldenResult: Equatable, Sendable {     // one seat on one golden brief
    public init(brief: String, known: Int, found: Int, raisedBlocker: Bool, confirmedClaims: Int, refutedClaims: Int)
}
public struct GoldenScore: Equatable, Sendable {
    public let briefs: Int
    public let recall: Share            // sum found / sum known over briefs with known > 0; a failure or abstention is found 0
    public let falseAlarm: Share        // clean briefs (known == 0) where raisedBlocker, over clean briefs
    public let confirmedShare: Share    // sum confirmedClaims / (confirmedClaims + refutedClaims)
    public static func score(_ results: [GoldenResult]) -> GoldenScore
}
public struct Floors: Equatable, Sendable { public var recall = 0.5; public var confirmedShare = 0.6; public var minBriefs = 10; public init() }
public enum GateDecision: Equatable, Sendable { case allowed; case blocked(reason: String) }
public enum VotingSeatGate {
    /// A seat on probation may vote only when it has at least `minBriefs` golden briefs, recall >= floor and
    /// confirmed share >= floor (an n=0 share fails). Not on probation: allowed. The reason names every failed
    /// check with its numbers, e.g. "golden recall 0.40 < 0.50".
    public static func check(onProbation: Bool, golden: GoldenScore?, floors: Floors) -> GateDecision
}
public enum ScoreExport {
    /// {"scores":[{seat,council,confirmedShare:{numerator,denominator,display},coverage,participation,
    ///  costPerConfirmed,medianSeconds}],"golden":{<seat>:{briefs,recall,falseAlarm,confirmedShare}}}.
    /// The string "recall" appears only inside "golden".
    public static func json(scores: [SeatScore], golden: [String: GoldenScore]) -> String
}
```

## Acceptance
As PLAN U11 "Acceptance", one test per bullet, plus: claim-id parsing edge cases, idempotent evidence,
adjudicator order and fail-closed unknown raiser, owner override after adjudication, adjudication rejected
after owner decision, `cannot tell` stays pending, 30-day boundary (29 days pending, 30 days unresolved),
Wilson reference rows (0/0 nil, 8/10, 1/1, 0/5, 50/100 to 3 decimals), `n=0` display, median time, cost per
confirmed, participation excludes nothing it should not, overlap, ScoreExport key audit, scoreboard timing.

## Accepted limits (recorded now)
- Change kind is the council type. Ring events from real sittings, the panel Confirm/Dismiss/Will fix actions and
  the broker `dispose` op land in a follow-up on this branch after the Core API is merged-ready; the add-seat sheet
  shows `VotingSeatGate`'s reason once a seat has golden data.
- Review follow-ups applied: the adjudicator is resolved by name against `seats` (the caller's copy is never trusted),
  an empty synthesizer vendor throws, check-and-write run in one `BEGIN IMMEDIATE` transaction, every outcome row is
  stamped strictly after the claim's latest one (whole-second stamps), the owner's word on any claim of a finding is
  final for the whole finding, probation floors that are NaN or infinite block, a repeated golden brief id counts once,
  and a revert is recognized only from a line that is exactly `This reverts commit <sha>`.
- The 50 ms scoreboard test is load-sensitive in a debug build: it passes alone (about 45 ms at load 16) and fails
  inside the full parallel suite when the Mac's load average is far above 30. The SQL (about 30 ms) dominates.
- Not yet verified: that git and `gh` provenance of evidence is real (the Core takes the commit and comment text it is
  handed); the sitting-time pipeline that calls `recordCommit`, spawns the adjudication seat and shows the actions.
